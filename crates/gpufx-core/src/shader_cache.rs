//! On-disk cache of compiled pipelines, enabled by `GPUFX_SHADER_CACHE=<directory>`.
//!
//! Each pipeline gets one file named by the SHA-256 of everything that affects its
//! compilation (final shader source with the prelude, language, entry point, output
//! format, gpufx and wgpu versions, backend, adapter and driver). On Vulkan with
//! `Features::PIPELINE_CACHE` the file (`.gpucache`) holds the data of a
//! `wgpu::PipelineCache`. On D3D12 with `Features::PASSTHROUGH_SHADERS` and
//! `dxcompiler.dll` on the DLL search path, it (`.dxil`) holds the DXIL gpufx compiled
//! itself, loaded back as a passthrough shader (see `dxil.rs`; the key then also has
//! the DXC version and shader model). Metal and GL have no on-disk cache in wgpu 30.
//!
//! Each file is the blob followed by its SHA-256, checked before the blob reaches
//! wgpu. The cache never makes compiling fail: an unreadable, truncated or corrupt file
//! is ignored and rewritten; a directory that cannot be used (or, on Unix, one that
//! other users can write) is reported once and the cache is turned off.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use sha2::{Digest, Sha256};

/// Version of the key layout; bump to orphan every file written before.
const KEY_VERSION: &str = "gpufx-shader-cache-1";
/// Exact versions of naga, wgpu-core and wgpu-hal (from Cargo.lock, see build.rs).
const WGPU_VERSION: &str = env!("GPUFX_WGPU_VERSIONS");
/// Total size kept in the directory unless `GPUFX_SHADER_CACHE_MAX_MB` says otherwise.
const DEFAULT_MAX_BYTES: u64 = 256 << 20;
const EXT: &str = "gpucache";
/// Extension of the DXIL files of D3D12.
#[cfg(windows)]
const DXIL_EXT: &str = "dxil";
/// Set once D3D12 refused DXIL that was just compiled (no `dxil.dll`, a driver that
/// rejects it...): later pipelines of the process skip DXC and go the normal way.
#[cfg(windows)]
static DXIL_REFUSED: AtomicBool = AtomicBool::new(false);

/// Counters of one [`ShaderCache`], for tests and logs.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ShaderCacheStats {
    /// Files read and handed to the driver (wgpu has no hit counter: the driver may still
    /// ignore the data).
    pub loaded: u64,
    /// Files written or rewritten.
    pub written: u64,
}

pub(crate) struct ShaderCache {
    dir: PathBuf,
    /// Adapter part of the key, computed once.
    adapter_key: String,
    /// Vulkan: `wgpu::PipelineCache` files.
    pipeline_cache: bool,
    /// D3D12: DXIL files compiled with this DXC.
    #[cfg(windows)]
    dxc: Option<&'static crate::dxil::DxcCompiler>,
    max_bytes: u64,
    disabled: AtomicBool,
    loaded: AtomicU64,
    written: AtomicU64,
}

/// What [`ShaderCache::begin`] gives to one pipeline creation.
pub(crate) struct Entry {
    path: PathBuf,
    pub(crate) cache: wgpu::PipelineCache,
    /// Whether a file existed and was read: then it is only rewritten if it changed.
    loaded: Option<Vec<u8>>,
}

/// What a pipeline is made of, besides its shader.
pub(crate) struct PipelineDesc<'a> {
    pub(crate) label: &'a str,
    pub(crate) layout: &'a wgpu::PipelineLayout,
    /// Entries of the one bind group of `layout`.
    #[cfg_attr(not(windows), allow(dead_code))]
    pub(crate) entries: &'a [wgpu::BindGroupLayoutEntry],
    pub(crate) entry: &'a str,
}

/// Whether a shader cache directory is given (`dir`, else `GPUFX_SHADER_CACHE`): devices
/// then ask for the features the cache needs.
pub(crate) fn configured(dir: Option<&Path>) -> bool {
    dir.is_some() || std::env::var_os("GPUFX_SHADER_CACHE").is_some_and(|v| !v.is_empty())
}

impl ShaderCache {
    /// The cache of `dir` (from `GPUFX_SHADER_CACHE` when `None`), or `None` when it is
    /// not set or the device cannot use one.
    pub(crate) fn new(dir: Option<PathBuf>, device: &wgpu::Device, info: &wgpu::AdapterInfo) -> Option<Self> {
        let dir = dir.or_else(|| std::env::var_os("GPUFX_SHADER_CACHE").filter(|v| !v.is_empty()).map(PathBuf::from))?;
        let pipeline_cache = device.features().contains(wgpu::Features::PIPELINE_CACHE) && wgpu::util::pipeline_cache_key(info).is_some();
        #[cfg(windows)]
        let dxc =
            (!pipeline_cache && info.backend == wgpu::Backend::Dx12 && device.features().contains(wgpu::Features::PASSTHROUGH_SHADERS))
                .then(crate::dxil::DxcCompiler::get)
                .flatten();
        #[cfg(windows)]
        let usable = pipeline_cache || dxc.is_some();
        #[cfg(not(windows))]
        let usable = pipeline_cache;
        if !usable {
            // Metal, GL, or D3D12 without dxcompiler.dll: wgpu 30 has no on-disk cache
            // there (driver caches still apply).
            return None;
        }
        if let Err(e) = std::fs::create_dir_all(&dir) {
            eprintln!("gpufx: shader cache {} disabled: {e}", dir.display());
            return None;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            // Files are fed to the driver: another user must not be able to plant them.
            match std::fs::metadata(&dir) {
                Ok(m) if m.permissions().mode() & 0o002 == 0 => {}
                Ok(_) => {
                    eprintln!("gpufx: shader cache {} disabled: writable by other users", dir.display());
                    return None;
                }
                Err(e) => {
                    eprintln!("gpufx: shader cache {} disabled: {e}", dir.display());
                    return None;
                }
            }
        }
        let max_bytes = std::env::var("GPUFX_SHADER_CACHE_MAX_MB")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .map_or(DEFAULT_MAX_BYTES, |mb| mb.saturating_mul(1 << 20));
        let adapter_key = format!(
            "{:?}\n{}\n{}\n{}\n{}\n{}\n{:?}",
            info.backend, info.name, info.vendor, info.device, info.driver, info.driver_info, info.device_type
        );
        let cache = ShaderCache {
            dir,
            adapter_key,
            pipeline_cache,
            #[cfg(windows)]
            dxc,
            max_bytes,
            disabled: AtomicBool::new(false),
            loaded: AtomicU64::new(0),
            written: AtomicU64::new(0),
        };
        // Once per context: keeps the directory under the limit and drops stale temp files.
        cache.prune();
        Some(cache)
    }

    pub(crate) fn stats(&self) -> ShaderCacheStats {
        ShaderCacheStats { loaded: self.loaded.load(Ordering::Relaxed), written: self.written.load(Ordering::Relaxed) }
    }

    /// File name for a pipeline: hex SHA-256 of every input of its compilation.
    fn file_name(&self, parts: &[&str], ext: &str) -> String {
        let mut h = Sha256::new();
        for p in [KEY_VERSION, env!("CARGO_PKG_VERSION"), WGPU_VERSION, &self.adapter_key].into_iter().chain(parts.iter().copied()) {
            // Length prefix: no two lists of parts hash the same.
            h.update((p.len() as u64).to_le_bytes());
            h.update(p.as_bytes());
        }
        let digest = h.finalize();
        let mut name: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        name.push('.');
        name.push_str(ext);
        name
    }

    /// A pipeline cache seeded from the file of `parts`, if any.
    pub(crate) fn begin(&self, device: &wgpu::Device, parts: &[&str]) -> Option<Entry> {
        if self.disabled.load(Ordering::Relaxed) {
            return None;
        }
        let path = self.dir.join(self.file_name(parts, EXT));
        let loaded = std::fs::read(&path).ok().and_then(verified);
        if loaded.is_some() {
            self.used(&path);
        }
        // SAFETY: the data was written by gpufx (our SHA-256 matched) into a directory
        // only this user can write. wgpu then checks its header (magic, version, ABI,
        // backend, adapter key, validation key, length) and with `fallback: true` creates
        // an empty cache on mismatch; the Vulkan driver checks its own header again.
        let cache = unsafe {
            device.create_pipeline_cache(&wgpu::PipelineCacheDescriptor {
                label: Some("gpufx pipeline cache"),
                data: loaded.as_deref(),
                fallback: true,
            })
        };
        Some(Entry { path, cache, loaded })
    }

    /// Writes the cache after the pipeline was created, unless it did not change.
    pub(crate) fn finish(&self, entry: Entry) {
        let Some(data) = entry.cache.get_data() else { return };
        if data.is_empty() || entry.loaded.as_deref() == Some(&data[..]) {
            return;
        }
        self.write(&entry.path, data);
    }

    /// Counts a file that was used and marks it as recently used.
    fn used(&self, path: &Path) {
        self.loaded.fetch_add(1, Ordering::Relaxed);
        // Lets the size limit drop the files not used for the longest time.
        if let Ok(f) = std::fs::File::options().append(true).open(path) {
            let _ = f.set_modified(std::time::SystemTime::now());
        }
    }

    /// Writes `data` and its SHA-256 to `path`.
    fn write(&self, path: &Path, mut file: Vec<u8>) {
        file.extend_from_slice(&Sha256::digest(&file));
        match write_atomic(path, &file) {
            Ok(()) => {
                self.written.fetch_add(1, Ordering::Relaxed);
            }
            // The directory itself is unusable: stop trying.
            Err(WriteError::Create(e)) if matches!(e.kind(), std::io::ErrorKind::PermissionDenied | std::io::ErrorKind::NotFound) => {
                if !self.disabled.swap(true, Ordering::Relaxed) {
                    eprintln!("gpufx: shader cache {} disabled: {e}", self.dir.display());
                }
            }
            // A full disk, a lost rename race...: skip this file only.
            Err(_) => {}
        }
    }

    /// The compute pipeline of `desc` running `module`, through `cache` when there is
    /// one. `parts` name every input of the compilation besides the adapter.
    pub(crate) fn compute_pipeline(
        cache: Option<&Self>,
        device: &wgpu::Device,
        desc: &PipelineDesc<'_>,
        module: naga::Module,
        parts: &[&str],
    ) -> wgpu::ComputePipeline {
        #[cfg(windows)]
        if let Some(pipeline) = cache.and_then(|c| c.dxil_pipeline(device, desc, &module, parts)) {
            return pipeline;
        }
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some(desc.label),
            source: wgpu::ShaderSource::Naga(std::borrow::Cow::Owned(module)),
        });
        let cache = cache.filter(|c| c.pipeline_cache);
        let entry = cache.and_then(|c| c.begin(device, parts));
        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some(desc.label),
            layout: Some(desc.layout),
            module: &shader,
            entry_point: Some(desc.entry),
            compilation_options: Default::default(),
            cache: entry.as_ref().map(|e| &e.cache),
        });
        // The cache object is dropped right after: only the file stays.
        if let (Some(c), Some(e)) = (cache, entry) {
            c.finish(e);
        }
        pipeline
    }

    /// D3D12: the pipeline from the DXIL file of `parts`, or from DXIL compiled now and
    /// then written. `None` sends the pipeline down the normal path (no DXC, HLSL or
    /// DXIL error, a layout `dxil.rs` does not cover, a file the driver refuses).
    #[cfg(windows)]
    fn dxil_pipeline(
        &self,
        device: &wgpu::Device,
        desc: &PipelineDesc<'_>,
        module: &naga::Module,
        parts: &[&str],
    ) -> Option<wgpu::ComputePipeline> {
        let dxc = self.dxc?;
        if self.disabled.load(Ordering::Relaxed) || DXIL_REFUSED.load(Ordering::Relaxed) {
            return None;
        }
        let ep = module.entry_points.iter().find(|ep| ep.name == desc.entry && ep.stage == naga::ShaderStage::Compute)?;
        let [x, y, z] = ep.workgroup_size;
        // The registers of the HLSL follow the layout: it is part of the key.
        let layout = format!("{:?}", desc.entries);
        let key: Vec<&str> =
            ["dxil", crate::dxil::SHADER_MODEL.to_str(), &dxc.version, &layout].into_iter().chain(parts.iter().copied()).collect();
        let path = self.dir.join(self.file_name(&key, DXIL_EXT));
        if let Some(dxil) = std::fs::read(&path).ok().and_then(verified) {
            if let Some(pipeline) = passthrough_pipeline(device, desc, (x, y, z), &dxil) {
                self.used(&path);
                return Some(pipeline);
            }
            // Refused (another DXC wrote it, a driver update...): rewritten below.
        }
        let (hlsl, name) = crate::dxil::hlsl(module, desc.entries, desc.entry)?;
        let dxil = dxc.compile(&hlsl, &name)?;
        let Some(pipeline) = passthrough_pipeline(device, desc, (x, y, z), &dxil) else {
            // Fresh DXIL refused too: D3D12 takes none on this machine (no dxil.dll...).
            // A file that was there is useless now.
            let _ = std::fs::remove_file(&path);
            if !DXIL_REFUSED.swap(true, Ordering::Relaxed) {
                eprintln!("gpufx: D3D12 refused the DXIL shaders, compiling them the normal way");
            }
            return None;
        };
        self.write(&path, dxil);
        Some(pipeline)
    }

    /// Removes temp files older than an hour, then the least recently used files while
    /// the directory is above the limit.
    fn prune(&self) {
        let Ok(dir) = std::fs::read_dir(&self.dir) else { return };
        let now = std::time::SystemTime::now();
        let mut files: Vec<_> = dir
            .filter_map(|e| e.ok())
            .filter(|e| {
                let path = e.path();
                let is_tmp = path.extension().and_then(|x| x.to_str()).is_some_and(|x| x.starts_with("tmp"));
                if is_tmp {
                    let old =
                        e.metadata().and_then(|m| m.modified()).is_ok_and(|t| now.duration_since(t).is_ok_and(|d| d.as_secs() > 3600));
                    if old {
                        let _ = std::fs::remove_file(&path);
                    }
                }
                path.extension().is_some_and(|x| x == EXT || cfg!(windows) && x == "dxil")
            })
            .filter_map(|e| {
                let m = e.metadata().ok()?;
                Some((m.modified().ok()?, m.len(), e.path()))
            })
            .collect();
        let mut total: u64 = files.iter().map(|f| f.1).sum();
        if total <= self.max_bytes {
            return;
        }
        files.sort();
        for (_, len, path) in files {
            if total <= self.max_bytes {
                break;
            }
            if std::fs::remove_file(&path).is_ok() {
                total -= len;
            }
        }
    }
}

/// The compute pipeline of `desc` from `dxil`, `None` if wgpu or the driver refuses it.
#[cfg(windows)]
fn passthrough_pipeline(
    device: &wgpu::Device,
    desc: &PipelineDesc<'_>,
    workgroup_size: (u32, u32, u32),
    dxil: &[u8],
) -> Option<wgpu::ComputePipeline> {
    let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
    let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
    // SAFETY: the DXIL was compiled by gpufx from naga's HLSL with the registers of
    // wgpu-hal's root signature for this layout (dxil.rs), now or in an earlier run; a
    // file is only used when its SHA-256 matches, from a directory only this user can
    // write, and the D3D12 runtime checks the hash and signature of the DXIL container.
    let module = unsafe {
        device.create_shader_module_passthrough(wgpu::ShaderModuleDescriptorPassthrough {
            label: Some(desc.label),
            entry_points: std::borrow::Cow::Owned(vec![wgpu::PassthroughShaderEntryPoint { name: desc.entry.into(), workgroup_size }]),
            dxil: Some(std::borrow::Cow::Borrowed(dxil)),
            ..Default::default()
        })
    };
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some(desc.label),
        layout: Some(desc.layout),
        module: &module,
        entry_point: Some(desc.entry),
        compilation_options: Default::default(),
        cache: None,
    });
    let failed = pollster::block_on(validation.pop()).is_some() | pollster::block_on(internal.pop()).is_some();
    (!failed).then_some(pipeline)
}

/// The wgpu blob of a cache file, if its trailing SHA-256 matches.
fn verified(mut file: Vec<u8>) -> Option<Vec<u8>> {
    let split = file.len().checked_sub(32).filter(|&n| n > 0)?;
    if Sha256::digest(&file[..split])[..] != file[split..] {
        return None;
    }
    file.truncate(split);
    Some(file)
}

enum WriteError {
    /// The temp file could not be created: the directory may be unusable.
    Create(std::io::Error),
    Other,
}

/// Writes through a temporary file in the same directory and renames it, so another
/// process never reads half a file.
fn write_atomic(path: &Path, data: &[u8]) -> Result<(), WriteError> {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.subsec_nanos());
    let tmp = path.with_extension(format!("tmp{}-{}-{nanos:09}", std::process::id(), SEQ.fetch_add(1, Ordering::Relaxed)));
    let mut f = std::fs::File::create_new(&tmp).map_err(WriteError::Create)?;
    let res = f.write_all(data).and_then(|()| f.sync_all());
    drop(f);
    if res.and_then(|()| std::fs::rename(&tmp, path)).is_err() {
        let _ = std::fs::remove_file(&tmp);
        return Err(WriteError::Other);
    }
    Ok(())
}
