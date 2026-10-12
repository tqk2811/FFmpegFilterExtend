//! GPU execution of an effect package with wgpu (Vulkan, DirectX 12, Metal, OpenGL).

use std::collections::HashMap;
use std::sync::Arc;

use crate::convert::{texture_2d, work_format, Converter, InputKey, InputSlot, OutputSlot};
use crate::frame::{Frame, FrameMut, PixelFormat};
use crate::manifest::{PassDef, ShaderLanguage, StreamInfo};
use crate::package::Package;
use crate::params::ParamBlock;
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

/// A GPU device. One context can be shared by many effects.
pub struct GpuContext {
    device: wgpu::Device,
    queue: wgpu::Queue,
    info: wgpu::AdapterInfo,
    conv: Converter,
}

impl GpuContext {
    pub fn new(backend: Backend) -> Result<Arc<Self>, Error> {
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
        // Output planes are encoded into storage buffers: allow what the adapter allows,
        // an 8K RGBA64 frame is above the 128 MiB default.
        let supported = adapter.limits();
        let required_limits = wgpu::Limits {
            max_storage_buffer_binding_size: supported.max_storage_buffer_binding_size,
            max_buffer_size: supported.max_buffer_size,
            ..Default::default()
        };
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("gpufx"),
            required_limits,
            ..Default::default()
        }))
        .map_err(|e| Error::Gpu(e.to_string()))?;
        let conv = Converter::new(&device);
        Ok(Arc::new(GpuContext { device, queue, info: adapter.get_info(), conv }))
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

const WORKGROUP: u32 = 8;
const FIRST_TEXTURE_BINDING: u32 = 4;

struct Pass {
    pipeline: wgpu::ComputePipeline,
    layout: wgpu::BindGroupLayout,
    inputs: Vec<String>,
    output: String,
}

/// Pass outputs and bind groups of one effect, for one set of input textures.
struct Bound {
    size: (u32, u32),
    /// Pass outputs are `rgba16float` (else `rgba8unorm`).
    deep: bool,
    outputs: HashMap<String, wgpu::Texture>,
    bind_groups: Vec<wgpu::BindGroup>,
}

/// Frame upload, conversion and readback resources, shared by the effects of a chain.
#[derive(Default)]
struct FrameIo {
    /// How many times textures or bind groups were made; see [`EffectChain::allocations`].
    allocations: usize,
    /// The frames of the chain carry more than 8 bits: see [`work_format`].
    deep: bool,
    inputs: Vec<InputSlot>,
    output: Option<OutputSlot>,
}

/// The immutable, compiled part of an effect: package, pipelines, textures and sampler.
/// One program can back many [`Effect`]s on the same device, so a package used by
/// several filters is read and compiled once.
pub struct Program {
    ctx: Arc<GpuContext>,
    package: Package,
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
    fn passes(&self, deep: bool) -> Result<&[Pass], Error> {
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
    program: Arc<Program>,
    params: ParamBlock,
    globals: wgpu::Buffer,
    params_buf: wgpu::Buffer,
    bound: Option<Bound>,
    /// Upload and readback buffers of [`Effect::process`]; a chain has its own.
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
        let res = run(std::slice::from_mut(self), &mut io, inputs, out, Some(info));
        self.io = Some(io);
        res
    }

    /// Creates the bind groups for `inputs` (one texture per manifest input) and the
    /// pass `outputs` handed out by `allocate`. Called again whenever they change.
    fn bind(
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
    fn output(&self) -> &wgpu::Texture {
        let bound = self.bound.as_ref().expect("bound before use");
        &bound.outputs[&self.program.package.manifest.passes.last().expect("validated").output]
    }

    fn encode(&self, cpass: &mut wgpu::ComputePass, info: &FrameInfo) {
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

/// Runs `effects` one after the other: the frames are uploaded once, every pass goes into
/// one command buffer and the result of the last effect is read back once. Effects after
/// the first take one input, the output of the effect before them. Without `info` the
/// effects are bypassed: input 0 is only converted to the output format.
fn run(effects: &mut [Effect], io: &mut FrameIo, inputs: &[Frame], mut out: FrameMut, info: Option<&FrameInfo>) -> Result<(), Error> {
    let first = &effects[0];
    let wanted = if info.is_some() { first.input_count() } else { 1 };
    if inputs.len() != wanted {
        return Err(Error::Frame(format!("effect expects {wanted} inputs, got {}", inputs.len())));
    }
    for (i, f) in inputs.iter().enumerate() {
        f.check(&format!("input {i}"))?;
    }
    let (w, h) = (inputs[0].width, inputs[0].height);
    out.check("output")?;
    if (out.width, out.height) != (w, h) {
        return Err(Error::Frame(format!(
            "output is {}x{}, the effect writes {w}x{h} (the size of the first input)",
            out.width, out.height
        )));
    }

    let ctx = first.program.ctx.clone();
    let (device, queue, conv) = (&ctx.device, &ctx.queue, &ctx.conv);
    let keys: Vec<InputKey> = inputs
        .iter()
        .map(|f| InputKey {
            format: f.format,
            width: f.width,
            height: f.height,
            direct: f.format == PixelFormat::Rgba && !f.color.premultiplied,
        })
        .collect();
    // A bypass call only brings input 0: keep the slots of the other inputs, and their
    // depth, so toggling the filter on and off does not rebuild anything.
    let others = if info.is_some() { &[][..] } else { io.inputs.get(1..).unwrap_or_default() };
    let deep = keys.iter().chain(others.iter().map(|slot| &slot.key)).any(|k| work_format(k.format) != wgpu::TextureFormat::Rgba8Unorm)
        || work_format(out.format) != wgpu::TextureFormat::Rgba8Unorm;
    let stale = io.deep != deep
        || if info.is_some() {
            io.inputs.len() != keys.len() || io.inputs.iter().zip(&keys).any(|(slot, k)| slot.key != *k)
        } else {
            io.inputs.first().is_none_or(|slot| slot.key != keys[0])
        };
    if stale {
        let mut keys = keys.clone();
        if info.is_none() {
            // Other inputs keep their keys, or take input 0's when there are none yet.
            for i in 1..first.input_count() {
                keys.push(io.inputs.get(i).map_or(keys[0], |slot| slot.key));
            }
        }
        // Size rules of the manifests; pixel formats are the caller's to check.
        let streams: Vec<StreamInfo> = keys.iter().map(|k| StreamInfo { format: None, width: k.width, height: k.height }).collect();
        first.package().manifest.check_inputs(&streams)?;
        for fx in &effects[1..] {
            fx.package().manifest.check_inputs(&streams[..1])?;
        }
        let names: Vec<String> = first.package().manifest.inputs.iter().map(|d| d.name.clone()).collect();
        // Drop the old textures before making new ones.
        io.inputs.clear();
        io.output = None;
        for fx in effects.iter_mut() {
            fx.bound = None;
        }
        io.deep = deep;
        io.allocations += 1;
        io.inputs = keys.iter().zip(&names).map(|(&k, d)| InputSlot::new(device, conv, d, k, deep)).collect();
        let mut prev: Vec<wgpu::Texture> = io.inputs.iter().map(|slot| slot.texture.clone()).collect();
        let outputs = allocate(effects, device, (w, h), deep)?;
        for (fx, outputs) in effects.iter_mut().zip(outputs) {
            fx.bind(&prev.iter().collect::<Vec<_>>(), outputs, (w, h), deep)?;
            prev = vec![fx.output().clone()];
        }
        // Its bind groups read textures that are gone.
        io.output = None;
    }
    if io.output.as_ref().is_none_or(|o| o.key != (out.format, w, h)) {
        io.output = Some(OutputSlot::new(device, out.format, w, h)?);
    }
    let output = io.output.as_mut().expect("just created");
    let bypass = info.is_none();
    if !output.is_bound(bypass) {
        let source = if bypass { &io.inputs[0].texture } else { effects.last().expect("at least one effect").output() };
        output.bind(device, conv, source, bypass);
        io.allocations += 1;
    }
    let output = io.output.as_ref().expect("just created");

    for (slot, f) in io.inputs.iter().zip(inputs) {
        slot.upload(queue, &f.planes, &f.strides, &f.color);
    }
    let mut enc = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx") });
    {
        let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx"), timestamp_writes: None });
        for slot in &io.inputs[..inputs.len()] {
            slot.encode(conv, &mut cpass);
        }
        if let Some(info) = info {
            for fx in effects.iter() {
                fx.encode(&mut cpass, info);
            }
        }
        output.encode(queue, conv, &mut cpass, &out.color, bypass);
    }
    output.copy(&mut enc);
    queue.submit([enc.finish()]);
    output.read(device, &mut out)
}

/// Hands out the pass output textures of every effect of a chain from a pool: a texture
/// goes back to the pool after the last pass that reads it, so a chain ping-pongs
/// between a few textures instead of keeping one per pass per effect.
fn allocate(
    effects: &[Effect],
    device: &wgpu::Device,
    (w, h): (u32, u32),
    deep: bool,
) -> Result<Vec<HashMap<String, wgpu::Texture>>, Error> {
    // Last pass (counted over the whole chain) that writes or reads each output.
    let mut last: HashMap<(usize, &str), usize> = HashMap::new();
    let mut g = 0;
    for (k, fx) in effects.iter().enumerate() {
        let m = &fx.program.package.manifest;
        let passes = fx.program.passes(deep)?;
        for pass in passes {
            for name in &pass.inputs {
                if passes.iter().any(|p| p.output == *name) {
                    last.insert((k, name), g);
                } else if k > 0 && m.inputs.iter().any(|d| d.name == *name) {
                    // The output of the effect before is this effect's input.
                    let prev = &effects[k - 1].program.passes(deep)?.last().expect("validated").output;
                    last.insert((k - 1, prev), g);
                }
            }
            let end = last.entry((k, &pass.output)).or_insert(g);
            *end = (*end).max(g);
            g += 1;
        }
    }
    let k_last = effects.len() - 1;
    let final_out = &effects[k_last].program.passes(deep)?.last().expect("validated").output;
    // Read by the output conversion.
    last.insert((k_last, final_out), usize::MAX);

    let format = if deep { wgpu::TextureFormat::Rgba16Float } else { wgpu::TextureFormat::Rgba8Unorm };
    let mut free: Vec<wgpu::Texture> = Vec::new();
    let mut live: Vec<(usize, wgpu::Texture)> = Vec::new();
    let mut maps = vec![HashMap::new(); effects.len()];
    let mut g = 0;
    for (k, fx) in effects.iter().enumerate() {
        for pass in fx.program.passes(deep)? {
            live.retain(|(end, tex)| {
                if *end < g {
                    free.push(tex.clone());
                }
                *end >= g
            });
            if !maps[k].contains_key(&pass.output) {
                let tex = free.pop().unwrap_or_else(|| {
                    texture_2d(
                        device,
                        "gpufx pass output",
                        w,
                        h,
                        format,
                        wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING,
                    )
                });
                live.push((last[&(k, pass.output.as_str())], tex.clone()));
                maps[k].insert(pass.output.clone(), tex);
            }
            g += 1;
        }
    }
    Ok(maps)
}

/// Effects run one after the other in one GPU submission, as if each fed the next
/// through its own filter, without the round trip to CPU memory in between.
pub struct EffectChain {
    effects: Vec<Effect>,
    labels: Vec<String>,
    /// Pixel format each effect after the first sees on its input, as two filters in a
    /// row would negotiate it. Frames stay RGBA on the GPU; only the rules are checked.
    links: Vec<String>,
    /// (effect, parameter) of every entry of `param_names`.
    params: Vec<(usize, usize)>,
    param_names: Vec<String>,
    io: FrameIo,
}

impl EffectChain {
    /// `effects` pairs a label (the package file name, used in parameter names such as
    /// `vignette.strength`) with an effect. All effects must share one GPU context.
    pub fn new(effects: Vec<(String, Effect)>) -> Result<Self, Error> {
        if effects.is_empty() {
            return Err(Error::Unsupported("a chain needs at least one effect".into()));
        }
        let (labels, effects): (Vec<String>, Vec<Effect>) = effects.into_iter().unzip();
        let ctx = &effects[0].program.ctx;
        let mut links = Vec::new();
        for (k, fx) in effects.iter().enumerate().skip(1) {
            let m = &fx.package().manifest;
            if !Arc::ptr_eq(&fx.program.ctx, ctx) {
                return Err(Error::Unsupported(format!("effect {k} (`{}`) runs on another GPU device", labels[k])));
            }
            if m.inputs.len() != 1 {
                return Err(Error::Unsupported(format!(
                    "effect {k} (`{}`) takes {} inputs; only the first effect of a chain may take more than one",
                    labels[k],
                    m.inputs.len()
                )));
            }
            // What gpufx=a,gpufx=b would negotiate: the first output format of `a` that
            // `b` accepts.
            let prev = &effects[k - 1].package().manifest;
            let accepted = &m.inputs[0].formats;
            let link = prev.output.formats.iter().find(|f| accepted.is_empty() || accepted.contains(f)).ok_or_else(|| {
                Error::Unsupported(format!(
                    "`{}` outputs {} but `{}` accepts {}",
                    labels[k - 1],
                    prev.output.formats.join(", "),
                    labels[k],
                    accepted.join(", ")
                ))
            })?;
            links.push(link.clone());
        }

        let mut params = Vec::new();
        let mut param_names = Vec::new();
        for (k, fx) in effects.iter().enumerate() {
            for (i, def) in fx.params.defs().iter().enumerate() {
                params.push((k, i));
                param_names.push(if effects.len() == 1 {
                    def.name.clone()
                } else if labels.iter().filter(|l| **l == labels[k]).count() == 1 && labels[k].parse::<usize>().is_err() {
                    format!("{}.{}", labels[k], def.name)
                } else {
                    format!("{k}.{}", def.name)
                });
            }
        }
        Ok(EffectChain { effects, labels, links, params, param_names, io: FrameIo::default() })
    }

    pub fn effects(&self) -> &[Effect] {
        &self.effects
    }

    pub fn labels(&self) -> &[String] {
        &self.labels
    }

    /// The first effect: its inputs are the inputs of the chain.
    pub fn first(&self) -> &Effect {
        &self.effects[0]
    }

    /// The last effect: its output rules are those of the chain.
    pub fn last(&self) -> &Effect {
        self.effects.last().expect("at least one effect")
    }

    /// Full names of every parameter: `name` for a single effect, else `label.name`, or
    /// `index.name` when two effects share a label.
    pub fn param_names(&self) -> &[String] {
        &self.param_names
    }

    /// Finds a parameter by its full name, by `label.name`, by `index.name` (0 based) or,
    /// when only one effect has it, by its bare name. A prefix made of digits is always an
    /// index, so a package named `2.zip` is reached by its index only.
    pub fn find_param(&self, name: &str) -> Result<usize, Error> {
        if let Some(i) = self.param_names.iter().position(|n| n == name) {
            return Ok(i);
        }
        let find = |k: usize, param: &str| self.params.iter().position(|&(e, p)| e == k && self.effects[e].params.defs()[p].name == param);
        if let Some((prefix, param)) = name.split_once('.') {
            let effect = match prefix.parse::<usize>() {
                Ok(k) if k < self.effects.len() => Some(k),
                Ok(_) => None,
                Err(_) => {
                    let matches: Vec<usize> = (0..self.labels.len()).filter(|&k| self.labels[k] == prefix).collect();
                    if matches.len() > 1 {
                        return Err(Error::Param(format!(
                            "`{prefix}` names {} effects of the chain; use the index, e.g. `{}.{param}`",
                            matches.len(),
                            matches[0]
                        )));
                    }
                    matches.first().copied()
                }
            };
            let Some(k) = effect else {
                return Err(Error::Param(format!("the chain has no effect `{prefix}` (effects: {})", self.labels.join(", "))));
            };
            return find(k, param).ok_or_else(|| Error::Param(format!("effect `{}` has no parameter `{param}`", self.labels[k])));
        }
        let owners: Vec<usize> = (0..self.effects.len()).filter_map(|k| find(k, name)).collect();
        match owners.as_slice() {
            [i] => Ok(*i),
            [] => Err(Error::Param(format!("no effect of the chain has a parameter `{name}`"))),
            _ => Err(Error::Param(format!(
                "several effects have a parameter `{name}`: {}",
                owners.iter().map(|&i| self.param_names[i].as_str()).collect::<Vec<_>>().join(", ")
            ))),
        }
    }

    /// Parameter `index` of `param_names` as (block, name inside its effect).
    fn param(&mut self, index: usize) -> Result<(&mut ParamBlock, String), Error> {
        let &(k, p) = self.params.get(index).ok_or_else(|| Error::Param(format!("no parameter {index}")))?;
        let block = &mut self.effects[k].params;
        let name = block.defs()[p].name.clone();
        Ok((block, name))
    }

    /// Sets a parameter (any name `find_param` takes) from text.
    pub fn set_param_str(&mut self, name: &str, text: &str) -> Result<(), Error> {
        let (block, name) = self.param(self.find_param(name)?)?;
        block.set_str(&name, text)
    }

    /// Sets the first components of a parameter (any name `find_param` takes).
    pub fn set_param(&mut self, name: &str, values: &[f64]) -> Result<(), Error> {
        let (block, name) = self.param(self.find_param(name)?)?;
        block.set(&name, values)
    }

    /// Checks one stream per input of the first effect against the rules of every effect:
    /// later effects see the first stream's size and the format negotiated in `new`.
    pub fn check_inputs(&self, streams: &[StreamInfo]) -> Result<(), Error> {
        self.first().package().manifest.check_inputs(streams)?;
        for (fx, link) in self.effects[1..].iter().zip(&self.links) {
            let s = StreamInfo { format: Some(link), width: streams[0].width, height: streams[0].height };
            fx.package().manifest.check_inputs(&[s])?;
        }
        Ok(())
    }

    /// Runs every effect on `inputs` (one per input of the first effect) and writes the
    /// RGBA result of the last one into `out`, which has the size of `inputs[0]`.
    pub fn process(&mut self, inputs: &[Image], out: ImageMut, info: &FrameInfo) -> Result<(), Error> {
        let frames: Vec<Frame> = inputs.iter().map(|&i| i.into()).collect();
        self.process_frames(&frames, out.into(), info)
    }

    /// [`EffectChain::process`] for frames in any [`PixelFormat`], converted on the GPU.
    pub fn process_frames(&mut self, inputs: &[Frame], out: FrameMut, info: &FrameInfo) -> Result<(), Error> {
        run(&mut self.effects, &mut self.io, inputs, out, Some(info))
    }

    /// How many times frame textures, buffers or bind groups were (re)made: once per new
    /// size or format, never per frame. For tests and diagnostics.
    pub fn allocations(&self) -> usize {
        self.io.allocations
    }

    /// Converts `input` (in place of input 0) to the format of `out` without running the
    /// effects, as a disabled filter passes its first input through.
    pub fn convert(&mut self, input: &Frame, out: FrameMut) -> Result<(), Error> {
        run(&mut self.effects, &mut self.io, std::slice::from_ref(input), out, None)
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
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some(&format!("gpufx pass {index}")),
        layout: Some(&pipeline_layout),
        module: &shader,
        entry_point: Some(entry),
        compilation_options: Default::default(),
        cache: None,
    });
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
