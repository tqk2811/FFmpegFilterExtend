//! GPU execution of an effect package with wgpu (Vulkan, DirectX 12, Metal, OpenGL).

use std::collections::HashMap;
use std::sync::Arc;

use crate::convert::{texture_2d, Converter};
use crate::frame::{Frame, FrameMut};
use crate::graph::{run, FrameIo, Topology};
use crate::manifest::{PassDef, ShaderLanguage};
use crate::package::Package;
use crate::params::ParamBlock;
use crate::shader_cache::{ShaderCache, ShaderCacheStats};
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

/// A GPU device. One context can be shared by many effects.
pub struct GpuContext {
    pub(crate) device: wgpu::Device,
    pub(crate) queue: wgpu::Queue,
    info: wgpu::AdapterInfo,
    pub(crate) conv: Converter,
    shader_cache: Option<ShaderCache>,
    /// Queue family of a shared Vulkan device (see `vulkan.rs`), `None` for devices
    /// gpufx made itself.
    #[cfg_attr(not(any(windows, all(unix, not(target_vendor = "apple")))), allow(dead_code))]
    pub(crate) vulkan_queue_family: Option<u32>,
    /// Held while Vulkan frames stage their semaphores and submit; true once a submission
    /// failed (the device is then no longer used for Vulkan frames).
    #[cfg_attr(not(any(windows, all(unix, not(target_vendor = "apple")))), allow(dead_code))]
    pub(crate) vulkan_submit: std::sync::Mutex<bool>,
    /// The D3D12 device shared with the caller (see `d3d12.rs`), `None` otherwise.
    #[cfg(windows)]
    pub(crate) d3d12: Option<crate::d3d12::Shared>,
}

impl GpuContext {
    /// A device on `backend`; `GPUFX_SHADER_CACHE` names the on-disk shader cache.
    pub fn new(backend: Backend) -> Result<Arc<Self>, Error> {
        Self::with_shader_cache(backend, None)
    }

    /// [`GpuContext::new`] with the shader cache in `cache_dir` (falls back to
    /// `GPUFX_SHADER_CACHE` when `None`).
    pub fn with_shader_cache(backend: Backend, cache_dir: Option<&std::path::Path>) -> Result<Arc<Self>, Error> {
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
        let adapter = request(false).or_else(|first| {
            request(true)
                .map_err(|fallback| Error::Gpu(format!("no GPU adapter for backend {backend:?}: {first}; software fallback: {fallback}")))
        })?;
        Self::open_adapter(&adapter, "gpufx", cache_dir)
    }

    /// A device on `adapter` with the features and limits gpufx uses.
    pub(crate) fn open_adapter(adapter: &wgpu::Adapter, label: &str, cache_dir: Option<&std::path::Path>) -> Result<Arc<Self>, Error> {
        // Output planes are encoded into storage buffers: allow what the adapter allows,
        // an 8K RGBA64 frame is above the 128 MiB default.
        let supported = adapter.limits();
        let required_limits = wgpu::Limits {
            max_storage_buffer_binding_size: supported.max_storage_buffer_binding_size,
            max_buffer_size: supported.max_buffer_size,
            ..Default::default()
        };
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some(label),
            required_limits,
            // PIPELINE_CACHE: only Vulkan has it in wgpu 30; it costs nothing until a cache
            // is created. The format features let GPU frames have 16-bit and r8/rg8
            // storage planes (see GpuFrame).
            required_features: adapter.features() & GPU_FEATURES,
            ..Default::default()
        }))
        .map_err(|e| Error::Gpu(e.to_string()))?;
        Ok(Self::from_device(device, queue, adapter.get_info(), cache_dir))
    }

    pub(crate) fn from_device(
        device: wgpu::Device,
        queue: wgpu::Queue,
        info: wgpu::AdapterInfo,
        cache_dir: Option<&std::path::Path>,
    ) -> Arc<Self> {
        let conv = Converter::new(&device);
        let shader_cache = ShaderCache::new(cache_dir.map(|d| d.to_path_buf()), &device, &info);
        Arc::new(GpuContext {
            device,
            queue,
            info,
            conv,
            shader_cache,
            vulkan_queue_family: None,
            vulkan_submit: std::sync::Mutex::new(false),
            #[cfg(windows)]
            d3d12: None,
        })
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
pub(crate) struct Bound {
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
    textures: HashMap<String, wgpu::Texture>,
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
            ..Default::default()
        });

        let mut textures = HashMap::new();
        for t in &package.manifest.textures {
            let img = image::load_from_memory(package.file(&t.path)?)
                .map_err(|e| Error::Package(format!("texture `{}`: {e}", t.path)))?
                .to_rgba8();
            // Package images stay 8-bit: they are only read.
            let (w, h) = (img.width(), img.height());
            let tex = texture_2d(
                device,
                &t.name,
                w,
                h,
                wgpu::TextureFormat::Rgba8Unorm,
                wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            );
            ctx.queue.write_texture(
                tex.as_image_copy(),
                img.as_raw(),
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(w * 4), rows_per_image: Some(h) },
                wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            );
            textures.insert(t.name.clone(), tex);
        }

        let mut passes = Vec::new();
        for (i, def) in package.manifest.passes.iter().enumerate() {
            passes.push(compile_pass(&ctx, &package, &params, i, def, false)?);
        }
        Ok(Arc::new(Program { ctx, package, passes, deep_passes: Default::default(), sampler, textures }))
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
        Ok(Effect { program, params, globals, params_buf, bound: None, io: None })
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
        let program = &self.program;
        let device = &program.ctx.device;
        let passes = program.passes(deep)?;
        let lookup = |name: &str| -> &wgpu::Texture {
            if let Some(i) = program.package.manifest.inputs.iter().position(|d| d.name == name) {
                inputs[i]
            } else if let Some(t) = program.textures.get(name) {
                t
            } else {
                &outputs[name]
            }
        };
        let bind_groups = passes
            .iter()
            .map(|pass| {
                let views: Vec<wgpu::TextureView> = pass.inputs.iter().map(|n| lookup(n).create_view(&Default::default())).collect();
                let out_view = outputs[&pass.output].create_view(&Default::default());
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
        self.bound = Some(Bound { size, deep, outputs, bind_groups });
        Ok(())
    }

    /// The texture the last pass writes. Only valid after `bind`.
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
        let passes = self.program.passes(bound.deep).expect("compiled in bind");
        for (pass, bg) in passes.iter().zip(&bound.bind_groups) {
            cpass.set_pipeline(&pass.pipeline);
            cpass.set_bind_group(0, bg, &[]);
            cpass.dispatch_workgroups(w.div_ceil(WORKGROUP), h.div_ceil(WORKGROUP), 1);
        }
    }
}

/// WGSL declarations prepended to every pass shader.
fn prelude(params: &ParamBlock, inputs: &[String], deep: bool) -> String {
    let mut s = String::from(
        "// ---- generated by gpufx ----\n\
         struct GpufxGlobals {\n    size: vec2f,\n    time: f32,\n    frame: u32,\n    \
         time_int: i32,\n    time_frac: f32,\n    pixel_aspect: f32,\n    gpufx_reserved: f32,\n};\n",
    );
    s.push_str(&params.wgsl_struct());
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
        s.push_str(&format!("@group(0) @binding({}) var {name}: texture_2d<f32>;\n", FIRST_TEXTURE_BINDING + i as u32));
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
fn glsl_with_prelude(params: &ParamBlock, inputs: &[String], user: &str, deep: bool) -> String {
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
    for (i, name) in inputs.iter().enumerate() {
        s.push_str(&format!("layout(set = 0, binding = {}) uniform texture2D {name};\n", FIRST_TEXTURE_BINDING + i as u32));
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
    let (module, source) = match def.language() {
        ShaderLanguage::Wgsl => {
            let source = format!("{}{}", prelude(params, &inputs, deep), pkg.text(&def.shader)?);
            let module = naga::front::wgsl::parse_str(&source)
                .map_err(|e| Error::Shader(format!("{}: {}", def.shader, e.emit_to_string(&source))))?;
            (module, source)
        }
        ShaderLanguage::Glsl => {
            let source = glsl_with_prelude(params, &inputs, pkg.text(&def.shader)?, deep);
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
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some(&def.shader),
        source: wgpu::ShaderSource::Naga(std::borrow::Cow::Owned(module)),
    });

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
    for i in 0..inputs.len() {
        entries.push(wgpu::BindGroupLayoutEntry {
            binding: FIRST_TEXTURE_BINDING + i as u32,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2,
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
    let cached = ctx.shader_cache.as_ref().and_then(|c| c.begin(device, &[language, entry, format, &source]));
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some(&format!("gpufx pass {index}")),
        layout: Some(&pipeline_layout),
        module: &shader,
        entry_point: Some(entry),
        compilation_options: Default::default(),
        cache: cached.as_ref().map(|e| &e.cache),
    });
    // The cache object is dropped right after: only the file stays.
    if let (Some(c), Some(e)) = (&ctx.shader_cache, cached) {
        c.finish(e);
    }
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
