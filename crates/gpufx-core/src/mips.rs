//! Mip chains of frame textures made on the GPU every frame, for effect inputs that ask
//! for `mipmaps` (see [`crate::manifest::InputDef::mipmaps`]). The chain lives in the
//! frame texture itself (levels 1..), so nothing is copied: each level is the alpha
//! weighted 2x2 average of the level above.

use std::sync::OnceLock;

const WORKGROUP: u32 = 8;

fn source(format: &str) -> String {
    format!(
        "@group(0) @binding(0) var src: texture_2d<f32>;\n\
         @group(0) @binding(1) var dst: texture_storage_2d<{format}, write>;\n\
         @compute @workgroup_size({WORKGROUP}, {WORKGROUP})\n\
         fn main(@builtin(global_invocation_id) id: vec3u) {{\n\
             let size = textureDimensions(dst);\n\
             if (id.x >= size.x || id.y >= size.y) {{ return; }}\n\
             let last = vec2i(textureDimensions(src)) - 1;\n\
             var acc = vec4f(0.0);\n\
             var plain = vec3f(0.0);\n\
             for (var k = 0; k < 4; k++) {{\n\
                 let p = min(vec2i(id.xy) * 2 + vec2i(k & 1, k >> 1), last);\n\
                 let c = textureLoad(src, p, 0);\n\
                 acc += vec4f(c.rgb * c.a, c.a);\n\
                 plain += c.rgb;\n\
             }}\n\
             // Straight alpha out: weighted by alpha, so transparent texels do not darken.\n\
             let rgb = select(plain * 0.25, acc.rgb / acc.a, acc.a > 0.0);\n\
             textureStore(dst, vec2i(id.xy), vec4f(rgb, acc.a * 0.25));\n\
         }}\n"
    )
}

/// A plain copy of level 0 of `src` into `dst`, for an effect of a graph switched off
/// (`<effect>.enable`): its output texture gets its first input, so the rest of the
/// graph stays bound as it was.
fn copy_source(format: &str) -> String {
    format!(
        "@group(0) @binding(0) var src: texture_2d<f32>;\n\
         @group(0) @binding(1) var dst: texture_storage_2d<{format}, write>;\n\
         @compute @workgroup_size({WORKGROUP}, {WORKGROUP})\n\
         fn main(@builtin(global_invocation_id) id: vec3u) {{\n\
             let size = textureDimensions(dst);\n\
             if (id.x >= size.x || id.y >= size.y) {{ return; }}\n\
             textureStore(dst, vec2i(id.xy), textureLoad(src, vec2i(id.xy), 0));\n\
         }}\n"
    )
}

/// The downsampling pipelines, compiled the first time a chain is made, and the copy
/// pipelines of effects switched off.
#[derive(Default)]
pub(crate) struct MipGen {
    /// For `rgba8unorm` and `rgba16float` textures: downsampling, then copying.
    pipelines: [OnceLock<(wgpu::ComputePipeline, wgpu::BindGroupLayout)>; 4],
}

impl MipGen {
    fn pipeline(&self, device: &wgpu::Device, format: wgpu::TextureFormat) -> &(wgpu::ComputePipeline, wgpu::BindGroupLayout) {
        self.make(device, format, false)
    }

    fn make(&self, device: &wgpu::Device, format: wgpu::TextureFormat, copy: bool) -> &(wgpu::ComputePipeline, wgpu::BindGroupLayout) {
        let deep = format == wgpu::TextureFormat::Rgba16Float;
        self.pipelines[deep as usize + 2 * copy as usize].get_or_init(|| {
            let name = if deep { "rgba16float" } else { "rgba8unorm" };
            let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("gpufx mips"),
                source: wgpu::ShaderSource::Wgsl(if copy { copy_source(name) } else { source(name) }.into()),
            });
            let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("gpufx mips"),
                entries: &[
                    wgpu::BindGroupLayoutEntry {
                        binding: 0,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 1,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::StorageTexture {
                            access: wgpu::StorageTextureAccess::WriteOnly,
                            format,
                            view_dimension: wgpu::TextureViewDimension::D2,
                        },
                        count: None,
                    },
                ],
            });
            let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("gpufx mips"),
                bind_group_layouts: &[Some(&layout)],
                immediate_size: 0,
            });
            let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some("gpufx mips"),
                layout: Some(&pipeline_layout),
                module: &module,
                entry_point: Some("main"),
                compilation_options: Default::default(),
                cache: None,
            });
            (pipeline, layout)
        })
    }

    /// The passes filling levels 1.. of `texture` from level 0.
    pub fn chain(&self, device: &wgpu::Device, texture: &wgpu::Texture) -> MipChain {
        let format = texture.format();
        let layout = &self.pipeline(device, format).1;
        let level = |l: u32| {
            texture.create_view(&wgpu::TextureViewDescriptor {
                base_mip_level: l,
                mip_level_count: Some(1),
                dimension: Some(wgpu::TextureViewDimension::D2),
                ..Default::default()
            })
        };
        let steps = (1..texture.mip_level_count())
            .map(|l| {
                let (src, dst) = (level(l - 1), level(l));
                let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("gpufx mips"),
                    layout,
                    entries: &[
                        wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&src) },
                        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dst) },
                    ],
                });
                let (w, h) = ((texture.width() >> l).max(1), (texture.height() >> l).max(1));
                (group, w, h)
            })
            .collect();
        MipChain { format, steps }
    }
}

impl MipGen {
    /// The bind group copying level 0 of `src` into `dst`, a storage texture of the same
    /// size in `rgba8unorm` or `rgba16float`.
    pub fn copy_group(&self, device: &wgpu::Device, src: &wgpu::Texture, dst: &wgpu::Texture) -> wgpu::BindGroup {
        let layout = &self.make(device, dst.format(), true).1;
        let level0 = |t: &wgpu::Texture| {
            t.create_view(&wgpu::TextureViewDescriptor {
                mip_level_count: Some(1),
                dimension: Some(wgpu::TextureViewDimension::D2),
                ..Default::default()
            })
        };
        let (src, dst) = (level0(src), level0(dst));
        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx copy"),
            layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&src) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dst) },
            ],
        })
    }

    /// Records a copy made by [`MipGen::copy_group`] into a `size` texture of `format`.
    pub fn encode_copy(
        &self,
        device: &wgpu::Device,
        format: wgpu::TextureFormat,
        group: &wgpu::BindGroup,
        size: (u32, u32),
        cpass: &mut wgpu::ComputePass,
    ) {
        cpass.set_pipeline(&self.make(device, format, true).0);
        cpass.set_bind_group(0, group, &[]);
        cpass.dispatch_workgroups(size.0.div_ceil(WORKGROUP), size.1.div_ceil(WORKGROUP), 1);
    }
}

/// The passes of one texture's mip chain, made once per texture.
pub(crate) struct MipChain {
    format: wgpu::TextureFormat,
    steps: Vec<(wgpu::BindGroup, u32, u32)>,
}

impl MipChain {
    pub fn encode(&self, device: &wgpu::Device, gen: &MipGen, cpass: &mut wgpu::ComputePass) {
        cpass.set_pipeline(&gen.pipeline(device, self.format).0);
        for (group, w, h) in &self.steps {
            cpass.set_bind_group(0, group, &[]);
            cpass.dispatch_workgroups(w.div_ceil(WORKGROUP), h.div_ceil(WORKGROUP), 1);
        }
    }
}

/// Bytes of levels 1.. of a full chain on a `w` x `h` texture of `texel` bytes.
pub(crate) fn chain_bytes(w: u32, h: u32, texel: u64) -> u64 {
    let levels = crate::texture::mip_levels(w, h);
    (1..levels).map(|l| (w >> l).max(1) as u64 * (h >> l).max(1) as u64 * texel).sum()
}
