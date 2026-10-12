//! GPU execution of an effect package with wgpu (Vulkan, DirectX 12, Metal, OpenGL).

use std::collections::HashMap;
use std::sync::Arc;

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
}

impl GpuContext {
    pub fn new(backend: Backend) -> Result<Arc<Self>, Error> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: backend.wgpu(),
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
        let (device, queue) =
            pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor { label: Some("gpufx"), ..Default::default() }))
                .map_err(|e| Error::Gpu(e.to_string()))?;
        Ok(Arc::new(GpuContext { device, queue, info: adapter.get_info() }))
    }

    /// e.g. `"NVIDIA GeForce RTX 4070 (Vulkan)"`.
    pub fn description(&self) -> String {
        format!("{} ({:?})", self.info.name, self.info.backend)
    }
}

/// A tightly or loosely packed RGBA8 image in CPU memory.
#[derive(Debug, Clone, Copy)]
pub struct Image<'a> {
    pub data: &'a [u8],
    pub width: u32,
    pub height: u32,
    /// Bytes per row; at least `width * 4`.
    pub stride: u32,
}

impl Image<'_> {
    fn check(&self, what: &str) -> Result<(), Error> {
        let ok = self.width > 0
            && self.height > 0
            && self.stride >= self.width * 4
            && self.data.len() as u64 >= (self.height as u64 - 1) * self.stride as u64 + self.width as u64 * 4;
        if ok {
            Ok(())
        } else {
            Err(Error::Frame(format!(
                "{what}: buffer does not hold a {}x{} RGBA image with stride {}",
                self.width, self.height, self.stride
            )))
        }
    }
}

const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;
const WORKGROUP: u32 = 8;
const FIRST_TEXTURE_BINDING: u32 = 4;

struct Pass {
    pipeline: wgpu::ComputePipeline,
    layout: wgpu::BindGroupLayout,
    inputs: Vec<String>,
    output: String,
}

/// GPU resources that depend on the input frame sizes.
struct Targets {
    sizes: Vec<(u32, u32)>,
    inputs: Vec<wgpu::Texture>,
    outputs: HashMap<String, wgpu::Texture>,
    bind_groups: Vec<wgpu::BindGroup>,
    readback: wgpu::Buffer,
    padded_row: u32,
}

/// The immutable, compiled part of an effect: package, pipelines, textures and sampler.
/// One program can back many [`Effect`]s on the same device, so a package used by
/// several filters is read and compiled once.
pub struct Program {
    ctx: Arc<GpuContext>,
    package: Package,
    passes: Vec<Pass>,
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
            let tex = create_texture(
                device,
                &t.name,
                img.width(),
                img.height(),
                wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            );
            upload(&ctx.queue, &tex, &Image { data: img.as_raw(), width: img.width(), height: img.height(), stride: img.width() * 4 });
            textures.insert(t.name.clone(), tex);
        }

        let mut passes = Vec::new();
        for (i, def) in package.manifest.passes.iter().enumerate() {
            passes.push(compile_pass(&ctx, &package, &params, i, def)?);
        }
        Ok(Arc::new(Program { ctx, package, passes, sampler, textures }))
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
    targets: Option<Targets>,
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
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let params_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx params"),
            size: params.size() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        Ok(Effect { program, params, globals, params_buf, targets: None })
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

    /// Runs every pass on `inputs` (one per manifest input) and writes the RGBA result,
    /// sized like `inputs[0]`, into `out` with row stride `out_stride`.
    /// Fails with [`Error::Unsupported`] when the input sizes break the manifest rules.
    pub fn process(&mut self, inputs: &[Image], out: &mut [u8], out_stride: u32, time: f64, frame: u64) -> Result<(), Error> {
        if inputs.len() != self.input_count() {
            return Err(Error::Frame(format!("effect expects {} inputs, got {}", self.input_count(), inputs.len())));
        }
        for (i, img) in inputs.iter().enumerate() {
            img.check(&format!("input {i}"))?;
        }
        let (w, h) = (inputs[0].width, inputs[0].height);
        Image { data: out, width: w, height: h, stride: out_stride }.check("output")?;

        let sizes: Vec<(u32, u32)> = inputs.iter().map(|i| (i.width, i.height)).collect();
        if self.targets.as_ref().is_none_or(|t| t.sizes != sizes) {
            // Size rules of the manifest; pixel formats are the caller's to check.
            let streams: Vec<StreamInfo> = sizes.iter().map(|&(width, height)| StreamInfo { format: None, width, height }).collect();
            self.program.package.manifest.check_inputs(&streams)?;
            self.targets = Some(self.create_targets(sizes));
        }
        let targets = self.targets.as_ref().expect("just created");
        let (device, queue) = (&self.program.ctx.device, &self.program.ctx.queue);

        for (tex, img) in targets.inputs.iter().zip(inputs) {
            upload(queue, tex, img);
        }
        let mut g = [0u8; 16];
        g[0..4].copy_from_slice(&(w as f32).to_le_bytes());
        g[4..8].copy_from_slice(&(h as f32).to_le_bytes());
        g[8..12].copy_from_slice(&(time as f32).to_le_bytes());
        g[12..16].copy_from_slice(&(frame as u32).to_le_bytes());
        queue.write_buffer(&self.globals, 0, &g);
        queue.write_buffer(&self.params_buf, 0, &self.params.bytes());

        let mut enc = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx") });
        {
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx"), timestamp_writes: None });
            for (pass, bg) in self.program.passes.iter().zip(&targets.bind_groups) {
                cpass.set_pipeline(&pass.pipeline);
                cpass.set_bind_group(0, bg, &[]);
                cpass.dispatch_workgroups(w.div_ceil(WORKGROUP), h.div_ceil(WORKGROUP), 1);
            }
        }
        let final_tex = &targets.outputs[&self.program.passes.last().expect("validated").output];
        enc.copy_texture_to_buffer(
            final_tex.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &targets.readback,
                layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(targets.padded_row), rows_per_image: Some(h) },
            },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        );
        queue.submit([enc.finish()]);

        let slice = targets.readback.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            let _ = tx.send(r);
        });
        device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| Error::Gpu(e.to_string()))?;
        rx.recv().map_err(|e| Error::Gpu(e.to_string()))?.map_err(|e| Error::Gpu(e.to_string()))?;
        {
            let mapped = slice.get_mapped_range().map_err(|e| Error::Gpu(e.to_string()))?;
            let row = (w * 4) as usize;
            for y in 0..h as usize {
                let src = &mapped[y * targets.padded_row as usize..][..row];
                out[y * out_stride as usize..][..row].copy_from_slice(src);
            }
        }
        targets.readback.unmap();
        Ok(())
    }

    fn create_targets(&self, sizes: Vec<(u32, u32)>) -> Targets {
        let program = &self.program;
        let device = &program.ctx.device;
        let (w, h) = sizes[0];
        let inputs: Vec<wgpu::Texture> = program
            .package
            .manifest
            .inputs
            .iter()
            .zip(&sizes)
            .map(|(def, &(iw, ih))| {
                create_texture(device, &def.name, iw, ih, wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST)
            })
            .collect();
        let mut outputs = HashMap::new();
        for pass in &program.passes {
            outputs.entry(pass.output.clone()).or_insert_with(|| {
                create_texture(
                    device,
                    &pass.output,
                    w,
                    h,
                    wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_SRC,
                )
            });
        }

        let lookup = |name: &str| -> &wgpu::Texture {
            if let Some(i) = program.package.manifest.inputs.iter().position(|d| d.name == name) {
                &inputs[i]
            } else if let Some(t) = program.textures.get(name) {
                t
            } else {
                &outputs[name]
            }
        };
        let bind_groups = program
            .passes
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

        let padded_row = (w * 4).next_multiple_of(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT);
        let readback = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("gpufx readback"),
            size: padded_row as u64 * h as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        Targets { sizes, inputs, outputs, bind_groups, readback, padded_row }
    }
}

fn create_texture(device: &wgpu::Device, label: &str, w: u32, h: u32, usage: wgpu::TextureUsages) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: FORMAT,
        usage,
        view_formats: &[],
    })
}

fn upload(queue: &wgpu::Queue, tex: &wgpu::Texture, img: &Image) {
    queue.write_texture(
        tex.as_image_copy(),
        img.data,
        wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(img.stride), rows_per_image: Some(img.height) },
        wgpu::Extent3d { width: img.width, height: img.height, depth_or_array_layers: 1 },
    );
}

/// WGSL declarations prepended to every pass shader.
fn prelude(params: &ParamBlock, inputs: &[String]) -> String {
    let mut s = String::from(
        "// ---- generated by gpufx ----\n\
         struct GpufxGlobals {\n    size: vec2f,\n    time: f32,\n    frame: u32,\n};\n",
    );
    s.push_str(&params.wgsl_struct());
    s.push_str(
        "@group(0) @binding(0) var<uniform> globals: GpufxGlobals;\n\
         @group(0) @binding(1) var<uniform> params: GpufxParams;\n\
         @group(0) @binding(2) var out_tex: texture_storage_2d<rgba8unorm, write>;\n\
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
fn glsl_with_prelude(params: &ParamBlock, inputs: &[String], user: &str) -> String {
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
         layout(set = 0, binding = 0) uniform GpufxGlobals {{ vec2 size; float time; uint frame; }} globals;\n\
         layout(set = 0, binding = 1) uniform GpufxParams {{\n{}}} params;\n\
         layout(set = 0, binding = 2, rgba8) uniform writeonly image2D out_tex;\n\
         layout(set = 0, binding = 3) uniform sampler smp;\n",
        params.glsl_members()
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

fn compile_pass(ctx: &GpuContext, pkg: &Package, params: &ParamBlock, index: usize, def: &PassDef) -> Result<Pass, Error> {
    let inputs: Vec<String> = match &def.inputs {
        Some(v) => v.clone(),
        None => pkg.manifest.inputs.iter().map(|i| i.name.clone()).chain(pkg.manifest.textures.iter().map(|t| t.name.clone())).collect(),
    };
    let (module, source) = match def.language() {
        ShaderLanguage::Wgsl => {
            let source = format!("{}{}", prelude(params, &inputs), pkg.text(&def.shader)?);
            let module = naga::front::wgsl::parse_str(&source)
                .map_err(|e| Error::Shader(format!("{}: {}", def.shader, e.emit_to_string(&source))))?;
            (module, source)
        }
        ShaderLanguage::Glsl => {
            let source = glsl_with_prelude(params, &inputs, pkg.text(&def.shader)?);
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
                format: FORMAT,
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
