//! GPU execution of an effect package with wgpu (Vulkan, DirectX 12, Metal, OpenGL).

use std::collections::HashMap;
use std::sync::Arc;

use crate::convert::Converter;
use crate::frame::{Frame, FrameMut};
use crate::graph::{run, FrameIo, Topology};
use crate::manifest::{PassDef, ShaderLanguage};
use crate::mips::MipGen;
use crate::package::Package;
use crate::params::ParamBlock;
use crate::shader_cache::{PipelineDesc, ShaderCache, ShaderCacheStats};
use crate::Error;

/// Graphics API to run on. `Auto` lets wgpu pick the best one for the platform.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Backend {
    #[default]
    Auto,
    Vulkan,
    Dx12,
    Metal,
    Gl,
}

impl std::str::FromStr for Backend {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Error> {
        Ok(match s.to_ascii_lowercase().as_str() {
            "" | "auto" => Backend::Auto,
            "vulkan" | "vk" => Backend::Vulkan,
            "dx12" | "d3d12" | "directx" => Backend::Dx12,
            "metal" | "mtl" => Backend::Metal,
            "gl" | "opengl" | "gles" => Backend::Gl,
            _ => return Err(Error::Gpu(format!("unknown backend `{s}`"))),
        })
    }
}

impl Backend {
    fn wgpu(self) -> wgpu::Backends {
        match self {
            Backend::Auto => wgpu::Backends::all(),
            Backend::Vulkan => wgpu::Backends::VULKAN,
            Backend::Dx12 => wgpu::Backends::DX12,
            Backend::Metal => wgpu::Backends::METAL,
            Backend::Gl => wgpu::Backends::GL,
        }
    }
}

/// Optional features a device asks for when the adapter has them.
pub(crate) const GPU_FEATURES: wgpu::Features = wgpu::Features::PIPELINE_CACHE
    .union(wgpu::Features::TEXTURE_FORMAT_16BIT_NORM)
    .union(wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES);

/// The high-performance adapter of `backend`, else its software fallback.
fn request_adapter(backend: Backend) -> Result<wgpu::Adapter, Error> {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: backend.wgpu(),
        // Honours WGPU_DX12_COMPILER (fxc, dxc) and the other backend variables.
        backend_options: wgpu::BackendOptions::from_env_or_default(),
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });
    let request = |force_fallback_adapter| {
        pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            force_fallback_adapter,
            compatible_surface: None,
            ..Default::default()
        }))
    };
    // Machines without a GPU (CI runners, servers) may still have a software adapter
    // such as WARP on Windows; try it before giving up.
    request(false).or_else(|first| {
        request(true)
            .map_err(|fallback| Error::Gpu(format!("no GPU adapter for backend {backend:?}: {first}; software fallback: {fallback}")))
    })
}

/// A device on `adapter` with the features and limits gpufx uses (see [`device_limits`])
/// plus `extra` when the adapter has them.
fn open_device(adapter: &wgpu::Adapter, label: &str, extra: wgpu::Features) -> Result<(wgpu::Device, wgpu::Queue), Error> {
    pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some(label),
        required_limits: device_limits(&adapter.limits()),
        // PIPELINE_CACHE: only Vulkan has it in wgpu 30; it costs nothing until a cache
        // is created. The format features let GPU frames have 16-bit and r8/rg8
        // storage planes (see GpuFrame).
        required_features: adapter.features() & (crate::profile::features() | extra),
        ..Default::default()
    }))
    .map_err(|e| Error::Gpu(e.to_string()))
}

/// Limits a device asks for, from what the adapter supports. Output planes are encoded into
/// storage buffers: allow what the adapter allows, an 8K RGBA64 frame is above the 128 MiB default.
/// `max_buffer_size` stays within `u32::MAX`: wgpu-core asserts it when it creates a device, and a
/// raw Vulkan adapter (`expose_adapter`) reports the driver's `maxBufferSize` unclamped (NVIDIA: above 4 GiB).
pub(crate) fn device_limits(supported: &wgpu::Limits) -> wgpu::Limits {
    let max_buffer_size = supported.max_buffer_size.min(u32::MAX as u64);
    wgpu::Limits {
        max_storage_buffer_binding_size: supported.max_storage_buffer_binding_size.min(max_buffer_size),
        max_buffer_size,
        ..Default::default()
    }
}

/// A GPU device. One context can be shared by many effects.
pub struct GpuContext {
    /// The D3D12 device shared with the caller (see `d3d12.rs`), `None` otherwise. First, so
    /// its D3D12 objects are released before `device`, whose drop may unload d3d12.dll
    /// (D3D11 frames also pin it, see `from_d3d11`, as graphs hold D3D12 objects too).
    #[cfg(windows)]
    pub(crate) d3d12: Option<crate::d3d12::Shared>,
    pub(crate) device: wgpu::Device,
    pub(crate) queue: wgpu::Queue,
    info: wgpu::AdapterInfo,
    pub(crate) conv: Converter,
    pub(crate) mips: MipGen,
    /// Per-frame textures and buffers shared by every graph on this device (see `pool.rs`).
    pub(crate) pool: crate::pool::Pool,
    shader_cache: Option<Arc<ShaderCache>>,
    /// Queue family of a shared Vulkan device (see `vulkan.rs`), `None` for devices
    /// gpufx made itself.
    #[cfg_attr(not(any(windows, all(unix, not(target_vendor = "apple")))), allow(dead_code))]
    pub(crate) vulkan_queue_family: Option<u32>,
    /// Held while Vulkan frames stage their semaphores and submit; true once a submission
    /// failed (the device is then no longer used for Vulkan frames).
    #[cfg_attr(not(any(windows, all(unix, not(target_vendor = "apple")))), allow(dead_code))]
    pub(crate) vulkan_submit: std::sync::Mutex<bool>,
}

impl GpuContext {
    /// A device on `backend`; `GPUFX_SHADER_CACHE` names the on-disk shader cache.
    pub fn new(backend: Backend) -> Result<Arc<Self>, Error> {
        Self::with_shader_cache(backend, None)
    }

    /// [`GpuContext::new`] with the shader cache in `cache_dir` (falls back to
    /// `GPUFX_SHADER_CACHE` when `None`).
    pub fn with_shader_cache(backend: Backend, cache_dir: Option<&std::path::Path>) -> Result<Arc<Self>, Error> {
        Self::open_adapter(&request_adapter(backend)?, "gpufx", cache_dir)
    }

    /// A D3D12 device whose shader cache records the DXIL of package pipelines (see
    /// [`crate::precompile`]).
    #[cfg(windows)]
    pub(crate) fn for_precompile() -> Result<Arc<Self>, Error> {
        let adapter = request_adapter(Backend::Dx12)?;
        if !adapter.features().contains(wgpu::Features::PASSTHROUGH_SHADERS) {
            return Err(Error::Gpu(format!("{} has no passthrough shaders", adapter.get_info().name)));
        }
        let (device, queue) = open_device(&adapter, "gpufx precompile", wgpu::Features::PASSTHROUGH_SHADERS)?;
        let info = adapter.get_info();
        let cache = ShaderCache::recorder(&device, &info)?;
        Ok(Self::assemble(device, queue, info, Some(Arc::new(cache))))
    }

    /// A device that runs nothing (wgpu's noop backend), to open effects before the device
    /// they run on is known: their shaders are compiled and checked, no GPU memory is used.
    pub fn noop() -> Result<Arc<Self>, Error> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::NOOP,
            backend_options: wgpu::BackendOptions {
                // It reports no format features: without the adapter's own, the WebGPU
                // defaults apply, which cover what effects use.
                noop: wgpu::NoopBackendOptions {
                    enable: true,
                    features: Some(GPU_FEATURES - wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES),
                    ..Default::default()
                },
                ..Default::default()
            },
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        let adapter = pollster::block_on(instance.request_adapter(&Default::default())).map_err(|e| Error::Gpu(e.to_string()))?;
        Self::open_adapter(&adapter, "gpufx noop", None)
    }

    /// A device on `adapter` with the features and limits gpufx uses (see [`device_limits`]).
    pub(crate) fn open_adapter(adapter: &wgpu::Adapter, label: &str, cache_dir: Option<&std::path::Path>) -> Result<Arc<Self>, Error> {
        let mut extra = wgpu::Features::empty();
        if adapter.get_info().backend == wgpu::Backend::Dx12 && crate::shader_cache::configured(cache_dir) {
            // The DXIL shader cache (dxil.rs) loads its shaders as passthrough shaders.
            extra |= wgpu::Features::PASSTHROUGH_SHADERS;
        }
        let (device, queue) = open_device(adapter, label, extra)?;
        Ok(Self::from_device(device, queue, adapter.get_info(), cache_dir))
    }

    pub(crate) fn from_device(
        device: wgpu::Device,
        queue: wgpu::Queue,
        info: wgpu::AdapterInfo,
        cache_dir: Option<&std::path::Path>,
    ) -> Arc<Self> {
        let shader_cache = ShaderCache::new(cache_dir.map(|d| d.to_path_buf()), &device, &info).map(Arc::new);
        Self::assemble(device, queue, info, shader_cache)
    }

    fn assemble(device: wgpu::Device, queue: wgpu::Queue, info: wgpu::AdapterInfo, shader_cache: Option<Arc<ShaderCache>>) -> Arc<Self> {
        let conv = Converter::new(&device, shader_cache.clone());
        Arc::new(GpuContext {
            device,
            queue,
            info,
            conv,
            mips: MipGen::default(),
            pool: Default::default(),
            shader_cache,
            vulkan_queue_family: None,
            vulkan_submit: std::sync::Mutex::new(false),
            #[cfg(windows)]
            d3d12: None,
        })
    }

    /// The shader cache, for [`crate::precompile`].
    #[cfg(windows)]
    pub(crate) fn shader_cache(&self) -> Option<&ShaderCache> {
        self.shader_cache.as_deref()
    }

    /// The wgpu device, to make textures for [`crate::GpuFrame`]s and command encoders
    /// for [`crate::EffectGraph::encode_gpu`].
    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }

    /// Counters of the on-disk shader cache, `None` when it is off or the backend has none.
    pub fn shader_cache_stats(&self) -> Option<ShaderCacheStats> {
        self.shader_cache.as_ref().map(|c| c.stats())
    }

    /// What the frame resource pool shared by the graphs of this device holds, for tests
    /// and diagnostics.
    pub fn pool_stats(&self) -> crate::PoolStats {
        self.pool.stats()
    }

    /// e.g. `"NVIDIA GeForce RTX 4070 (Vulkan)"`.
    pub fn description(&self) -> String {
        format!("{} ({:?})", self.info.name, self.info.backend)
    }
}

/// A tightly or loosely packed RGBA8 image in CPU memory. [`Frame`] takes other formats.
#[derive(Debug, Clone, Copy)]
pub struct Image<'a> {
    pub data: &'a [u8],
    pub width: u32,
    pub height: u32,
    /// Bytes per row; at least `width * 4`.
    pub stride: u32,
}

/// Where an effect writes its RGBA8 result.
#[derive(Debug)]
pub struct ImageMut<'a> {
    pub data: &'a mut [u8],
    pub width: u32,
    pub height: u32,
    /// Bytes per row; at least `width * 4`.
    pub stride: u32,
}

/// Per-frame values exposed to shaders through `globals`.
#[derive(Debug, Clone, Copy)]
pub struct FrameInfo {
    /// Presentation time in seconds.
    pub time: f64,
    /// Index of the frame.
    pub frame: u64,
    /// Width of a pixel divided by its height (sample aspect ratio), 1 for square pixels.
    pub pixel_aspect: f64,
}

impl FrameInfo {
    pub fn new(time: f64, frame: u64) -> Self {
        FrameInfo { time, frame, pixel_aspect: 1.0 }
    }
}

/// Size of the `GpufxGlobals` uniform struct.
const GLOBALS_SIZE: u64 = 32;

/// `GpufxGlobals` as the shaders see it: see `prelude`.
fn globals_bytes(size: (u32, u32), info: &FrameInfo) -> [u8; GLOBALS_SIZE as usize] {
    // f32 time loses precision as the clip goes on (a 1 day timestamp moves by about
    // 0.008 s steps), so whole seconds and the fraction are also given apart.
    // Beyond the i32 range (68 years) the time saturates.
    let t = if info.time.is_finite() { info.time.clamp(i32::MIN as f64, i32::MAX as f64) } else { 0.0 };
    let whole = t.floor();
    let mut frac = (t - whole) as f32;
    let mut whole = whole as i32;
    if frac >= 1.0 {
        // t just below an integer rounds up in f32.
        frac = 0.0;
        whole = whole.saturating_add(1);
    }
    let pixel_aspect = if info.pixel_aspect.is_finite() && info.pixel_aspect > 0.0 { info.pixel_aspect } else { 1.0 };
    let mut g = [0u8; GLOBALS_SIZE as usize];
    g[0..4].copy_from_slice(&(size.0 as f32).to_le_bytes());
    g[4..8].copy_from_slice(&(size.1 as f32).to_le_bytes());
    g[8..12].copy_from_slice(&(t as f32).to_le_bytes());
    g[12..16].copy_from_slice(&(info.frame as u32).to_le_bytes());
    g[16..20].copy_from_slice(&whole.to_le_bytes());
    g[20..24].copy_from_slice(&frac.to_le_bytes());
    g[24..28].copy_from_slice(&(pixel_aspect as f32).to_le_bytes());
    g
}

pub(crate) const WORKGROUP: u32 = 8;
const FIRST_TEXTURE_BINDING: u32 = 4;

pub(crate) struct Pass {
    pipeline: wgpu::ComputePipeline,
    layout: wgpu::BindGroupLayout,
    pub(crate) inputs: Vec<String>,
    pub(crate) output: String,
}

/// Pass outputs and bind groups of one effect, for one set of input textures.
#[derive(Clone)]
pub(crate) struct Bound {
    /// The input textures, to bind again when the pipelines change.
    inputs: Vec<wgpu::Texture>,
    size: (u32, u32),
    /// Pass outputs are `rgba16float` (else `rgba8unorm`).
    deep: bool,
    outputs: HashMap<String, wgpu::Texture>,
    bind_groups: Vec<wgpu::BindGroup>,
}

/// The immutable, compiled part of an effect: package, pipelines, textures and sampler.
/// One program can back many [`Effect`]s on the same device, so a package used by
/// several filters is read and compiled once.
pub struct Program {
    pub(crate) ctx: Arc<GpuContext>,
    pub(crate) package: Package,
    /// Pipelines writing `rgba8unorm`, for chains of 8-bit frames.
    passes: Vec<Pass>,
    /// Pipelines writing `rgba16float`, compiled the first time a deeper frame comes.
    deep_passes: std::sync::OnceLock<Result<Vec<Pass>, String>>,
    sampler: wgpu::Sampler,
    /// Texts of the `expr` parameter defaults the pipelines were built with.
    pub(crate) default_exprs: Vec<String>,
    /// Package textures, viewed with their dimension and every mip level.
    textures: HashMap<String, wgpu::TextureView>,
}

impl Program {
    pub fn new(ctx: Arc<GpuContext>, package: Package) -> Result<Arc<Self>, Error> {
        // Only the layout of the block matters for compiling; values live in each Effect.
        let params = ParamBlock::new(&package.manifest.params)?;
        let device = &ctx.device;
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("gpufx sampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            // Only textures with mips see this: one-level textures sample as before.
            mipmap_filter: wgpu::MipmapFilterMode::Linear,
            ..Default::default()
        });

        let limits = device.limits();
        let mut textures = HashMap::new();
        for t in &package.manifest.textures {
            let texels = crate::texture::load(&package, t)?;
            let (w, h, layers) = (texels.width, texels.height, texels.layers);
            // Checked here, not left to wgpu: its errors go to the device error handler,
            // which panics by default and would take the host process down.
            if w > limits.max_texture_dimension_2d || h > limits.max_texture_dimension_2d {
                return Err(Error::Gpu(format!(
                    "texture `{}` is {w}x{h}, this device allows {} a side",
                    t.name, limits.max_texture_dimension_2d
                )));
            }
            if layers > limits.max_texture_array_layers {
                return Err(Error::Gpu(format!(
                    "texture `{}` has {layers} layers, this device allows {}",
                    t.name, limits.max_texture_array_layers
                )));
            }
            // Package images stay 8-bit: they are only read.
            let tex = device.create_texture(&wgpu::TextureDescriptor {
                label: Some(&t.name),
                size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: layers },
                mip_level_count: texels.levels.len() as u32,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            for (level, data) in texels.levels.iter().enumerate() {
                let (lw, lh) = ((w >> level).max(1), (h >> level).max(1));
                ctx.queue.write_texture(
                    wgpu::TexelCopyTextureInfo { mip_level: level as u32, ..tex.as_image_copy() },
                    data,
                    wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(lw * 4), rows_per_image: Some(lh) },
                    wgpu::Extent3d { width: lw, height: lh, depth_or_array_layers: layers },
                );
            }
            let dimension = if texels.array { wgpu::TextureViewDimension::D2Array } else { wgpu::TextureViewDimension::D2 };
            let view = tex.create_view(&wgpu::TextureViewDescriptor { dimension: Some(dimension), ..Default::default() });
            textures.insert(t.name.clone(), view);
        }

        let mut passes = Vec::new();
        for (i, def) in package.manifest.passes.iter().enumerate() {
            passes.push(compile_pass(&ctx, &package, &params, i, def, false)?);
        }
        let default_exprs = params.expr_key().into_iter().map(String::from).collect();
        Ok(Arc::new(Program { ctx, package, passes, deep_passes: Default::default(), sampler, default_exprs, textures }))
    }

    /// The pipelines for one work format; the shaders were validated in `new`.
    pub(crate) fn passes(&self, deep: bool) -> Result<&[Pass], Error> {
        if !deep {
            return Ok(&self.passes);
        }
        let compiled = self.deep_passes.get_or_init(|| {
            let params = ParamBlock::new(&self.package.manifest.params).map_err(|e| e.to_string())?;
            let defs = self.package.manifest.passes.iter().enumerate();
            defs.map(|(i, def)| compile_pass(&self.ctx, &self.package, &params, i, def, true).map_err(|e| e.to_string())).collect()
        });
        // Compiled when the first frame above 8 bits comes: name the package in errors.
        compiled.as_deref().map_err(|e| Error::Shader(format!("{} (rgba16float variant): {e}", self.package.manifest.name)))
    }

    pub fn context(&self) -> &Arc<GpuContext> {
        &self.ctx
    }

    pub fn package(&self) -> &Package {
        &self.package
    }
}

/// An instance of a [`Program`] with its own parameter values and frame buffers.
pub struct Effect {
    pub(crate) program: Arc<Program>,
    pub(crate) params: ParamBlock,
    globals: wgpu::Buffer,
    params_buf: wgpu::Buffer,
    pub(crate) bound: Option<Bound>,
    /// Upload and readback buffers of [`Effect::process`]; a graph has its own.
    io: Option<FrameIo>,
    /// Pipelines built for this effect's own `expr` values, when they differ from the
    /// package defaults the program was compiled with.
    own: Option<OwnPasses>,
    /// Bindings of recent frame textures made by [`Effect::rebind`], until the next `bind`.
    rebinds: crate::lru::Lru<(Vec<wgpu::Texture>, Option<wgpu::Texture>), Bound>,
}

/// Pipelines of an effect whose `expr` parameters were changed.
struct OwnPasses {
    key: Vec<String>,
    passes: Vec<Pass>,
    deep_passes: std::sync::OnceLock<Result<Vec<Pass>, String>>,
}

impl Effect {
    /// Loads and compiles `package` for this effect alone.
    pub fn new(ctx: Arc<GpuContext>, package: Package) -> Result<Self, Error> {
        Self::from_program(Program::new(ctx, package)?)
    }

    /// Creates an effect that shares the compiled `program` with other effects.
    pub fn from_program(program: Arc<Program>) -> Result<Self, Error> {
        let params = ParamBlock::new(&program.package.manifest.params)?;
        let device = &program.ctx.device;
        let globals = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx globals"),
            size: GLOBALS_SIZE,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let params_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx params"),
            size: params.size() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        Ok(Effect { program, params, globals, params_buf, bound: None, io: None, own: None, rebinds: Default::default() })
    }

    pub fn program(&self) -> &Arc<Program> {
        &self.program
    }

    pub fn package(&self) -> &Package {
        &self.program.package
    }

    pub fn params(&self) -> &ParamBlock {
        &self.params
    }

    pub fn params_mut(&mut self) -> &mut ParamBlock {
        &mut self.params
    }

    pub fn input_count(&self) -> usize {
        self.program.package.manifest.inputs.len()
    }

    /// The pipelines for one work format: the program's, or this effect's own.
    pub(crate) fn passes(&self, deep: bool) -> Result<&[Pass], Error> {
        let Some(own) = &self.own else { return self.program.passes(deep) };
        if !deep {
            return Ok(&own.passes);
        }
        let program = &self.program;
        let compiled = own.deep_passes.get_or_init(|| {
            let defs = program.package.manifest.passes.iter().enumerate();
            defs.map(|(i, def)| compile_pass(&program.ctx, &program.package, &self.params, i, def, true).map_err(|e| e.to_string()))
                .collect()
        });
        compiled.as_deref().map_err(|e| Error::Shader(format!("{} (rgba16float variant): {e}", program.package.manifest.name)))
    }

    /// Rebuilds the pipelines when an `expr` parameter changed since they were built
    /// (a few milliseconds: change expressions now and then, not every frame), and binds
    /// them to the current textures. On failure the expressions go back to those of the
    /// current pipelines, so the effect keeps running and the failure is not retried.
    pub(crate) fn sync_exprs(&mut self) -> Result<(), Error> {
        let res = self.try_sync_exprs();
        if res.is_err() {
            let good = self.own.as_ref().map_or(&self.program.default_exprs, |own| &own.key).clone();
            self.params.restore_exprs(&good);
        }
        res
    }

    fn try_sync_exprs(&mut self) -> Result<(), Error> {
        let key = self.params.expr_key();
        let current = self.own.as_ref().map_or(&self.program.default_exprs, |own| &own.key);
        if key == *current {
            return Ok(());
        }
        let key: Vec<String> = key.into_iter().map(String::from).collect();
        if key == self.program.default_exprs {
            // Back to the defaults: the program's pipelines.
            self.own = None;
        } else {
            let program = &self.program;
            let defs = program.package.manifest.passes.iter().enumerate();
            let passes = defs
                .map(|(i, def)| compile_pass(&program.ctx, &program.package, &self.params, i, def, false))
                .collect::<Result<Vec<_>, _>>()?;
            let own = OwnPasses { key, passes, deep_passes: Default::default() };
            let previous = self.own.replace(own);
            // Bound to deep frames: build that variant now, so binding cannot fail.
            if self.bound.as_ref().is_some_and(|b| b.deep) {
                if let Err(e) = self.passes(true).map(|_| ()) {
                    self.own = previous;
                    return Err(e);
                }
            }
        }
        if let Some(bound) = self.bound.take() {
            let inputs = bound.inputs.clone();
            self.bind(&inputs.iter().collect::<Vec<_>>(), bound.outputs, bound.size, bound.deep)?;
        }
        Ok(())
    }

    /// Runs every pass on `inputs` (one per manifest input) and writes the RGBA result
    /// into `out`, which must have the size of `inputs[0]`.
    /// Fails with [`Error::Unsupported`] when the input sizes break the manifest rules.
    pub fn process(&mut self, inputs: &[Image], out: ImageMut, info: &FrameInfo) -> Result<(), Error> {
        let frames: Vec<Frame> = inputs.iter().map(|&i| i.into()).collect();
        self.process_frames(&frames, out.into(), info)
    }

    /// [`Effect::process`] for frames in any [`PixelFormat`]: they are converted to and
    /// from RGBA on the GPU.
    pub fn process_frames(&mut self, inputs: &[Frame], out: FrameMut, info: &FrameInfo) -> Result<(), Error> {
        let mut io = self.io.take().unwrap_or_default();
        let topo = Topology::single(self.input_count());
        let res = run(std::slice::from_mut(self), &topo, &mut io, inputs, &mut [out], Some(info));
        self.io = Some(io);
        res
    }

    /// Creates the bind groups for `inputs` (one texture per manifest input) and the
    /// pass `outputs` handed out by `allocate`. Called again whenever they change.
    pub(crate) fn bind(
        &mut self,
        inputs: &[&wgpu::Texture],
        outputs: HashMap<String, wgpu::Texture>,
        size: (u32, u32),
        deep: bool,
    ) -> Result<(), Error> {
        self.rebinds.clear();
        self.bound = Some(self.make_bound(inputs, outputs, size, deep)?);
        Ok(())
    }

    fn make_bound(
        &self,
        inputs: &[&wgpu::Texture],
        outputs: HashMap<String, wgpu::Texture>,
        size: (u32, u32),
        deep: bool,
    ) -> Result<Bound, Error> {
        let program = &self.program;
        let device = &program.ctx.device;
        let passes = self.passes(deep)?;
        let manifest = &program.package.manifest;
        // Frame textures are seen at level 0 only, unless the input asks for its mips.
        let level0 = |t: &wgpu::Texture| t.create_view(&wgpu::TextureViewDescriptor { mip_level_count: Some(1), ..Default::default() });
        let lookup = |name: &str| -> wgpu::TextureView {
            if let Some(i) = manifest.inputs.iter().position(|d| d.name == name) {
                if manifest.inputs[i].mipmaps {
                    inputs[i].create_view(&Default::default())
                } else {
                    level0(inputs[i])
                }
            } else if let Some(t) = program.textures.get(name) {
                t.clone()
            } else {
                level0(&outputs[name])
            }
        };
        let bind_groups = passes
            .iter()
            .map(|pass| {
                let views: Vec<wgpu::TextureView> = pass.inputs.iter().map(|n| lookup(n)).collect();
                let out_view = level0(&outputs[&pass.output]);
                let mut entries = vec![
                    wgpu::BindGroupEntry { binding: 0, resource: self.globals.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 1, resource: self.params_buf.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&out_view) },
                    wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&program.sampler) },
                ];
                for (i, v) in views.iter().enumerate() {
                    entries.push(wgpu::BindGroupEntry {
                        binding: FIRST_TEXTURE_BINDING + i as u32,
                        resource: wgpu::BindingResource::TextureView(v),
                    });
                }
                device.create_bind_group(&wgpu::BindGroupDescriptor { label: Some("gpufx pass"), layout: &pass.layout, entries: &entries })
            })
            .collect();
        let inputs = inputs.iter().map(|&t| t.clone()).collect();
        Ok(Bound { inputs, size, deep, outputs, bind_groups })
    }

    /// The texture the last pass writes. Only valid after `bind`.
    /// Binds the effect again on `inputs`, keeping its pass textures, with the texture of
    /// its last pass replaced by `output` when given (a frame written in place). The
    /// bindings of recent textures are reused (the frames of a pool come back in turn);
    /// returns whether new ones were made.
    pub(crate) fn rebind(&mut self, inputs: &[&wgpu::Texture], output: Option<&wgpu::Texture>) -> Result<bool, Error> {
        let bound = self.bound.as_ref().ok_or_else(|| Error::Gpu("the effect is not bound".into()))?;
        let mut outputs = bound.outputs.clone();
        if let Some(t) = output {
            outputs.insert(self.program.package.manifest.passes.last().expect("validated").output.clone(), t.clone());
        }
        let (size, deep) = (bound.size, bound.deep);
        let key = (inputs.iter().map(|&t| t.clone()).collect(), output.cloned());
        let mut rebinds = std::mem::take(&mut self.rebinds);
        let made = rebinds.get_or_make(key, |_| self.make_bound(inputs, outputs, size, deep)).map(|(bound, made)| {
            self.bound = Some(bound.clone());
            made
        });
        self.rebinds = rebinds;
        made
    }

    pub(crate) fn output(&self) -> &wgpu::Texture {
        let bound = self.bound.as_ref().expect("bound before use");
        &bound.outputs[&self.program.package.manifest.passes.last().expect("validated").output]
    }

    pub(crate) fn encode(&self, cpass: &mut wgpu::ComputePass, info: &FrameInfo) {
        let bound = self.bound.as_ref().expect("bound before use");
        let queue = &self.program.ctx.queue;
        queue.write_buffer(&self.globals, 0, &globals_bytes(bound.size, info));
        queue.write_buffer(&self.params_buf, 0, &self.params.bytes());
        let (w, h) = bound.size;
        let passes = self.passes(bound.deep).expect("compiled in bind");
        for (pass, bg) in passes.iter().zip(&bound.bind_groups) {
            cpass.set_pipeline(&pass.pipeline);
            cpass.set_bind_group(0, bg, &[]);
            cpass.dispatch_workgroups(w.div_ceil(WORKGROUP), h.div_ceil(WORKGROUP), 1);
        }
    }
}

/// WGSL declarations prepended to every pass shader.
fn prelude(params: &ParamBlock, inputs: &[String], arrays: &[bool], deep: bool) -> String {
    let mut s = String::from(
        "// ---- generated by gpufx ----\n\
         struct GpufxGlobals {\n    size: vec2f,\n    time: f32,\n    frame: u32,\n    \
         time_int: i32,\n    time_frac: f32,\n    pixel_aspect: f32,\n    gpufx_reserved: f32,\n};\n",
    );
    s.push_str(&params.wgsl_struct());
    s.push_str(&params.expr_functions(false));
    s.push_str(
        "@group(0) @binding(0) var<uniform> globals: GpufxGlobals;\n\
         @group(0) @binding(1) var<uniform> params: GpufxParams;\n\
         @group(0) @binding(2) var out_tex: texture_storage_2d<",
    );
    s.push_str(if deep { "rgba16float" } else { "rgba8unorm" });
    s.push_str(
        ", write>;\n\
         @group(0) @binding(3) var smp: sampler;\n",
    );
    for (i, name) in inputs.iter().enumerate() {
        let ty = if arrays[i] { "texture_2d_array" } else { "texture_2d" };
        s.push_str(&format!("@group(0) @binding({}) var {name}: {ty}<f32>;\n", FIRST_TEXTURE_BINDING + i as u32));
    }
    s.push_str(
        "fn gpufx_in_bounds(id: vec3u) -> bool { return f32(id.x) < globals.size.x && f32(id.y) < globals.size.y; }\n\
         fn gpufx_uv(id: vec3u) -> vec2f { return (vec2f(id.xy) + 0.5) / globals.size; }\n\
         fn gpufx_write(id: vec3u, c: vec4f) { textureStore(out_tex, vec2i(id.xy), clamp(c, vec4f(0.0), vec4f(1.0))); }\n\
         // ---- end of gpufx prelude ----\n",
    );
    s
}

/// Inserts the GLSL prelude after the author's `#version` line (adding `#version 450`
/// when there is none), so their line numbers stay readable in errors.
fn glsl_with_prelude(params: &ParamBlock, inputs: &[String], arrays: &[bool], user: &str, deep: bool) -> String {
    let (version, body) = match user.trim_start().strip_prefix("#version") {
        Some(rest) => {
            let rest_at = user.len() - rest.len();
            let eol = user[rest_at..].find('\n').map_or(user.len(), |i| rest_at + i + 1);
            (&user[..eol], &user[eol..])
        }
        None => ("#version 450\n", user),
    };
    let mut s = String::from(version);
    s.push_str(&format!(
        "// ---- generated by gpufx ----\n\
         layout(set = 0, binding = 0) uniform GpufxGlobals {{ vec2 size; float time; uint frame; \
         int time_int; float time_frac; float pixel_aspect; float gpufx_reserved; }} globals;\n\
         layout(set = 0, binding = 1) uniform GpufxParams {{\n{}}} params;\n\
         layout(set = 0, binding = 2, {}) uniform writeonly image2D out_tex;\n\
         layout(set = 0, binding = 3) uniform sampler smp;\n",
        params.glsl_members(),
        if deep { "rgba16f" } else { "rgba8" }
    ));
    s.push_str(&params.expr_functions(true));
    for (i, name) in inputs.iter().enumerate() {
        let ty = if arrays[i] { "texture2DArray" } else { "texture2D" };
        s.push_str(&format!("layout(set = 0, binding = {}) uniform {ty} {name};\n", FIRST_TEXTURE_BINDING + i as u32));
    }
    s.push_str(
        "bool gpufx_in_bounds(uvec3 id) { return float(id.x) < globals.size.x && float(id.y) < globals.size.y; }\n\
         vec2 gpufx_uv(uvec3 id) { return (vec2(id.xy) + 0.5) / globals.size; }\n\
         void gpufx_write(uvec3 id, vec4 c) { imageStore(out_tex, ivec2(id.xy), clamp(c, vec4(0.0), vec4(1.0))); }\n\
         // ---- end of gpufx prelude ----\n",
    );
    s.push_str(body);
    s
}

fn compile_pass(ctx: &GpuContext, pkg: &Package, params: &ParamBlock, index: usize, def: &PassDef, deep: bool) -> Result<Pass, Error> {
    let inputs: Vec<String> = match &def.inputs {
        Some(v) => v.clone(),
        None => pkg.manifest.inputs.iter().map(|i| i.name.clone()).chain(pkg.manifest.textures.iter().map(|t| t.name.clone())).collect(),
    };
    let arrays: Vec<bool> = inputs.iter().map(|n| pkg.manifest.textures.iter().any(|t| t.name == *n && t.is_array())).collect();
    let (module, source) = match def.language() {
        ShaderLanguage::Wgsl => {
            let source = format!("{}{}", prelude(params, &inputs, &arrays, deep), pkg.text(&def.shader)?);
            let module = naga::front::wgsl::parse_str(&source)
                .map_err(|e| Error::Shader(format!("{}: {}", def.shader, e.emit_to_string(&source))))?;
            (module, source)
        }
        ShaderLanguage::Glsl => {
            let source = glsl_with_prelude(params, &inputs, &arrays, pkg.text(&def.shader)?, deep);
            let module = naga::front::glsl::Frontend::default()
                .parse(&naga::front::glsl::Options::from(naga::ShaderStage::Compute), &source)
                .map_err(|e| Error::Shader(format!("{}: {}", def.shader, e.emit_to_string(&source))))?;
            (module, source)
        }
    };
    let entry = match def.language() {
        ShaderLanguage::Wgsl => def.entry.as_str(),
        ShaderLanguage::Glsl => "main",
    };

    // Validate here: wgpu would otherwise only report shader errors through the device
    // error callback, which cannot be returned to the caller.
    naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::empty())
        .validate(&module)
        .map_err(|e| Error::Shader(format!("{}: {}", def.shader, e.emit_to_string(&source))))?;
    if !module.entry_points.iter().any(|ep| ep.name == entry && ep.stage == naga::ShaderStage::Compute) {
        return Err(Error::Shader(format!("{}: no compute entry point `{entry}`", def.shader)));
    }

    let device = &ctx.device;

    let mut entries = vec![
        uniform_entry(0),
        uniform_entry(1),
        wgpu::BindGroupLayoutEntry {
            binding: 2,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::StorageTexture {
                access: wgpu::StorageTextureAccess::WriteOnly,
                format: if deep { wgpu::TextureFormat::Rgba16Float } else { wgpu::TextureFormat::Rgba8Unorm },
                view_dimension: wgpu::TextureViewDimension::D2,
            },
            count: None,
        },
        wgpu::BindGroupLayoutEntry {
            binding: 3,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
            count: None,
        },
    ];
    for (i, &array) in arrays.iter().enumerate() {
        entries.push(wgpu::BindGroupLayoutEntry {
            binding: FIRST_TEXTURE_BINDING + i as u32,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: if array { wgpu::TextureViewDimension::D2Array } else { wgpu::TextureViewDimension::D2 },
                multisampled: false,
            },
            count: None,
        });
    }
    let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("gpufx pass"), entries: &entries });
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("gpufx pass"),
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let language = match def.language() {
        ShaderLanguage::Wgsl => "wgsl",
        ShaderLanguage::Glsl => "glsl",
    };
    let format = if deep { "rgba16float" } else { "rgba8unorm" };
    let pipeline = ShaderCache::compute_pipeline(
        ctx.shader_cache.as_deref(),
        device,
        &PipelineDesc { label: &format!("gpufx pass {index} ({})", def.shader), layout: &pipeline_layout, entries: &entries, entry },
        module,
        &[language, entry, format, &source],
        Some(pkg),
    );
    Ok(Pass { pipeline, layout, inputs, output: def.output.clone() })
}

fn uniform_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
        count: None,
    }
}

#[cfg(test)]
mod tests {
    use super::device_limits;

    #[test]
    fn device_limits_keep_max_buffer_size_within_u32() {
        // A raw Vulkan adapter on NVIDIA reports maxBufferSize above 4 GiB; wgpu-core panics on it.
        let huge = wgpu::Limits { max_buffer_size: 1 << 40, max_storage_buffer_binding_size: 1 << 40, ..Default::default() };
        let limits = device_limits(&huge);
        assert_eq!(limits.max_buffer_size, u32::MAX as u64);
        assert_eq!(limits.max_storage_buffer_binding_size, u32::MAX as u64);

        let small = wgpu::Limits { max_buffer_size: 256 << 20, ..Default::default() };
        assert_eq!(device_limits(&small).max_buffer_size, 256 << 20);
    }
}
