//! Built-in GPU passes that convert frames between their pixel format and the RGBA
//! textures effects work on, so YUV never goes through the CPU.
//!
//! Input planes are uploaded as integer textures (`r8uint`, `rg16uint`, ...: core WebGPU
//! formats every backend has, unlike `r16unorm`) and turned into an RGBA texture with
//! straight alpha, which the first effect reads. Straight 8-bit RGBA skips the pass and
//! is read as `rgba8unorm`. The RGBA textures are `rgba16float` only when a frame of the
//! chain has more than 8 bits, else `rgba8unorm` (half the memory).
//! On output a pass encodes each plane into a storage buffer of packed words, which is
//! copied into a mappable buffer and from there into the caller's planes.

use std::sync::OnceLock;

use crate::frame::{ColorInfo, FrameMut, Layout, PixelFormat, PlaneKind};
use crate::pool::PoolKey;
use crate::Error;

/// RGBA texture format that keeps the precision of `format`: `rgba16float` (about 11
/// bits) above 8 bits. A chain works in the deepest format of its frames.
pub(crate) fn work_format(format: PixelFormat) -> wgpu::TextureFormat {
    deep_format(format.layout().depth > 8)
}

fn deep_format(deep: bool) -> wgpu::TextureFormat {
    if deep {
        wgpu::TextureFormat::Rgba16Float
    } else {
        wgpu::TextureFormat::Rgba8Unorm
    }
}
const WORKGROUP: u32 = 8;
/// Size of the `Conv` uniform struct of convert.wgsl.
const UNIFORM_SIZE: u64 = 112;

/// Pipelines of the conversion passes, compiled once per device. Those for frames
/// already on the GPU are compiled the first time such a frame comes.
pub(crate) struct Converter {
    device: wgpu::Device,
    /// Integer planes uploaded from the CPU, writing `rgba8unorm` and `rgba16float`.
    to_rgba: [(wgpu::ComputePipeline, wgpu::BindGroupLayout); 2],
    /// Unorm planes of GPU frames, writing `rgba8unorm` and `rgba16float`.
    to_rgba_gpu: OnceLock<[(wgpu::ComputePipeline, wgpu::BindGroupLayout); 2]>,
    from_rgba: wgpu::ComputePipeline,
    from_rgba_layout: wgpu::BindGroupLayout,
    /// Writing the planes of GPU frames, one per plane texture format.
    to_planes: [OnceLock<(wgpu::ComputePipeline, wgpu::BindGroupLayout)>; PLANE_FORMATS.len()],
    /// Bound in place of the planes a format does not have.
    dummy: wgpu::TextureView,
    dummy_gpu: OnceLock<wgpu::TextureView>,
}

/// Plane texture formats of GPU frames, with their WGSL storage format names.
const PLANE_FORMATS: [(wgpu::TextureFormat, &str); 6] = [
    (wgpu::TextureFormat::R8Unorm, "r8unorm"),
    (wgpu::TextureFormat::Rg8Unorm, "rg8unorm"),
    (wgpu::TextureFormat::Rgba8Unorm, "rgba8unorm"),
    (wgpu::TextureFormat::R16Unorm, "r16unorm"),
    (wgpu::TextureFormat::Rg16Unorm, "rg16unorm"),
    (wgpu::TextureFormat::Rgba16Unorm, "rgba16unorm"),
];

fn entry(binding: u32, ty: wgpu::BindingType) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry { binding, visibility: wgpu::ShaderStages::COMPUTE, ty, count: None }
}

const UNIFORM: wgpu::BindingType =
    wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None };

fn texture(sample_type: wgpu::TextureSampleType) -> wgpu::BindingType {
    wgpu::BindingType::Texture { sample_type, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false }
}

fn pipeline(
    device: &wgpu::Device,
    label: &str,
    body: &str,
    entries: &[wgpu::BindGroupLayoutEntry],
) -> (wgpu::ComputePipeline, wgpu::BindGroupLayout) {
    let common = include_str!("convert.wgsl");
    let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some(label),
        source: wgpu::ShaderSource::Wgsl(format!("{common}{body}").into()),
    });
    let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some(label), entries });
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some(label),
        bind_group_layouts: &[Some(&layout)],
        immediate_size: 0,
    });
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some(label),
        layout: Some(&pipeline_layout),
        module: &module,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });
    (pipeline, layout)
}

/// convert_in.wgsl with its plane bindings: integer textures (CPU uploads) or unorm
/// textures (GPU frames), read back as the stored sample codes.
fn convert_in_source(deep: bool, unorm: bool) -> String {
    let mut s = String::new();
    for i in 0..4 {
        if unorm {
            s.push_str(&format!(
                "@group(0) @binding({}) var plane{i}: texture_2d<f32>;\n\
                 fn load{i}(p: vec2i) -> vec4u {{ return vec4u(round(textureLoad(plane{i}, p, 0) * unorm_max())); }}\n",
                2 + i
            ));
        } else {
            s.push_str(&format!(
                "@group(0) @binding({}) var plane{i}: texture_2d<u32>;\n\
                 fn load{i}(p: vec2i) -> vec4u {{ return textureLoad(plane{i}, p, 0); }}\n",
                2 + i
            ));
        }
    }
    if unorm {
        s.push_str("fn unorm_max() -> f32 { return select(255.0, 65535.0, cv.depth + cv.shift > 8u); }\n");
    }
    let wgsl = if deep { "rgba16float" } else { "rgba8unorm" };
    s.push_str(&include_str!("convert_in.wgsl").replace("rgba16float", wgsl));
    s
}

fn to_rgba_pipelines(device: &wgpu::Device, unorm: bool) -> [(wgpu::ComputePipeline, wgpu::BindGroupLayout); 2] {
    let plane = texture(if unorm { wgpu::TextureSampleType::Float { filterable: false } } else { wgpu::TextureSampleType::Uint });
    [false, true].map(|deep| {
        pipeline(
            device,
            "gpufx convert in",
            &convert_in_source(deep, unorm),
            &[
                entry(0, UNIFORM),
                entry(
                    1,
                    wgpu::BindingType::StorageTexture {
                        access: wgpu::StorageTextureAccess::WriteOnly,
                        format: deep_format(deep),
                        view_dimension: wgpu::TextureViewDimension::D2,
                    },
                ),
                entry(2, plane),
                entry(3, plane),
                entry(4, plane),
                entry(5, plane),
            ],
        )
    })
}

impl Converter {
    pub fn new(device: &wgpu::Device) -> Self {
        let to_rgba = to_rgba_pipelines(device, false);
        let (from_rgba, from_rgba_layout) = pipeline(
            device,
            "gpufx convert out",
            &format!("{}{}", include_str!("convert_out.wgsl"), include_str!("convert_out_buffer.wgsl")),
            &[
                entry(0, UNIFORM),
                // textureLoad only, so rgba8unorm inputs (bypass) and rgba16float both fit.
                entry(1, texture(wgpu::TextureSampleType::Float { filterable: false })),
                entry(
                    2,
                    wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: false },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                ),
            ],
        );
        let dummy = texture_2d(device, "gpufx dummy plane", 1, 1, wgpu::TextureFormat::R8Uint, wgpu::TextureUsages::TEXTURE_BINDING)
            .create_view(&Default::default());
        Converter {
            device: device.clone(),
            to_rgba,
            to_rgba_gpu: OnceLock::new(),
            from_rgba,
            from_rgba_layout,
            to_planes: Default::default(),
            dummy,
            dummy_gpu: OnceLock::new(),
        }
    }

    fn to_rgba(&self, gpu: bool, deep: bool) -> &(wgpu::ComputePipeline, wgpu::BindGroupLayout) {
        if gpu {
            &self.to_rgba_gpu.get_or_init(|| to_rgba_pipelines(&self.device, true))[deep as usize]
        } else {
            &self.to_rgba[deep as usize]
        }
    }

    fn dummy(&self, gpu: bool) -> &wgpu::TextureView {
        if !gpu {
            return &self.dummy;
        }
        self.dummy_gpu.get_or_init(|| {
            texture_2d(&self.device, "gpufx dummy plane", 1, 1, wgpu::TextureFormat::R8Unorm, wgpu::TextureUsages::TEXTURE_BINDING)
                .create_view(&Default::default())
        })
    }

    /// The pass writing a plane texture of `format`.
    fn to_plane(&self, format: wgpu::TextureFormat) -> Result<&(wgpu::ComputePipeline, wgpu::BindGroupLayout), Error> {
        let i = PLANE_FORMATS
            .iter()
            .position(|&(f, _)| f == format)
            .ok_or_else(|| Error::Frame(format!("{format:?} is not a plane format of GPU frames")))?;
        Ok(self.to_planes[i].get_or_init(|| {
            let body = format!(
                "{}{}",
                include_str!("convert_out.wgsl"),
                include_str!("convert_out_image.wgsl").replace("STORAGE_FORMAT", PLANE_FORMATS[i].1)
            );
            pipeline(
                &self.device,
                "gpufx convert out (gpu)",
                &body,
                &[
                    entry(0, UNIFORM),
                    entry(1, texture(wgpu::TextureSampleType::Float { filterable: false })),
                    entry(
                        2,
                        wgpu::BindingType::StorageTexture {
                            access: wgpu::StorageTextureAccess::WriteOnly,
                            format,
                            view_dimension: wgpu::TextureViewDimension::D2,
                        },
                    ),
                ],
            )
        }))
    }
}

pub(crate) fn texture_2d(
    device: &wgpu::Device,
    label: &str,
    w: u32,
    h: u32,
    format: wgpu::TextureFormat,
    usage: wgpu::TextureUsages,
) -> wgpu::Texture {
    texture_2d_mips(device, label, w, h, format, usage, false)
}

/// [`texture_2d`], with a full mip chain when `mips` (filled by [`crate::mips`]).
pub(crate) fn texture_2d_mips(
    device: &wgpu::Device,
    label: &str,
    w: u32,
    h: u32,
    format: wgpu::TextureFormat,
    usage: wgpu::TextureUsages,
    mips: bool,
) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: if mips { crate::texture::mip_levels(w, h) } else { 1 },
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage,
        view_formats: &[],
    })
}

/// Integer texture format of plane `plane` of `format`.
fn plane_format(format: PixelFormat, plane: usize) -> wgpu::TextureFormat {
    use wgpu::TextureFormat as T;
    let (_, _, channels) = format.plane_dims(plane, 1, 1);
    match (channels, format.layout().bytes) {
        (4, 1) => T::Rgba8Uint,
        (4, _) => T::Rgba16Uint,
        (2, 1) => T::Rg8Uint,
        (2, _) => T::Rg16Uint,
        (_, 1) => T::R8Uint,
        _ => T::R16Uint,
    }
}

/// Bytes of the `Conv` uniform: frame and colour fields, then the output plane fields.
fn uniform(format: PixelFormat, w: u32, h: u32, color: &ColorInfo, plane: Option<usize>) -> [u8; UNIFORM_SIZE as usize] {
    let l: Layout = format.layout();
    let (kr, kb) = color.matrix.kr_kb();
    let (site_x, site_y) = color.chroma_location.siting();
    let mut words: Vec<u32> = vec![
        w,
        h,
        w.div_ceil(l.sub.0),
        h.div_ceil(l.sub.1),
        l.sub.0,
        l.sub.1,
        l.kind as u32,
        l.alpha as u32,
        l.depth,
        l.shift,
        (color.range == crate::frame::Range::Full) as u32,
        color.premultiplied as u32,
        kr.to_bits(),
        kb.to_bits(),
        site_x.to_bits(),
        site_y.to_bits(),
    ];
    if let Some(p) = plane {
        let (pw, ph, channels) = format.plane_dims(p, w, h);
        let (row_bytes, _) = format.plane_size(p, w, h);
        let chroma = (pw, ph) != (w, h);
        // Channels of each interleaved sample: 0 Y/R, 1 U/G, 2 V/B, 3 A.
        let ch: [u32; 4] = match (l.kind, p) {
            (PlaneKind::Rgba, _) => [0, 1, 2, 3],
            (PlaneKind::SemiPlanar, 1) => [1, 2, 0, 0],
            (PlaneKind::Planar, 1) => [1, 0, 0, 0],
            (PlaneKind::Planar, 2) => [2, 0, 0, 0],
            (PlaneKind::Planar, 3) => [3, 0, 0, 0],
            _ => [0, 0, 0, 0],
        };
        words.extend([pw, ph, channels, l.bytes, row_bytes.div_ceil(4), chroma as u32]);
        words.extend(ch);
    }
    words.resize(UNIFORM_SIZE as usize / 4, 0);
    let mut out = [0u8; UNIFORM_SIZE as usize];
    for (dst, word) in out.as_chunks_mut::<4>().0.iter_mut().zip(words) {
        *dst = word.to_le_bytes();
    }
    out
}

fn uniform_buffer(device: &wgpu::Device, label: &str) -> wgpu::Buffer {
    device.create_buffer(&wgpu::BufferDescriptor {
        label: Some(label),
        size: UNIFORM_SIZE,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    })
}

/// What an input slot was made for; a frame with another key needs a new slot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct InputKey {
    pub format: PixelFormat,
    pub width: u32,
    pub height: u32,
    /// Straight RGBA8: uploaded as `rgba8unorm` and read by effects without a pass.
    pub direct: bool,
    /// A [`crate::GpuFrame`]: no upload, the conversion pass reads its plane textures.
    pub gpu: bool,
}

/// Upload textures of one input and, unless direct, its conversion pass. Reused from
/// frame to frame while the key holds.
pub(crate) struct InputSlot {
    pub key: InputKey,
    /// Upload textures; none for GPU frames.
    planes: Vec<wgpu::Texture>,
    /// The texture the first effect reads: the RGBA8 plane itself, or the target of the
    /// conversion pass.
    pub texture: wgpu::Texture,
    /// Uniforms of the conversion pass, unless direct.
    uniform: Option<wgpu::Buffer>,
    /// Made once for uploads, per frame for GPU frames (their textures change).
    bind_group: Option<wgpu::BindGroup>,
    deep: bool,
}

impl InputSlot {
    /// The textures of a slot, borrowed from the context pool: the upload planes, then
    /// the converted frame unless direct. `deep`: convert into `rgba16float` rather than
    /// `rgba8unorm`. `mips`: the texture effects read has a mip chain (filled by the
    /// caller after `encode`).
    pub fn pool_keys(key: InputKey, deep: bool, mips: bool) -> Vec<PoolKey> {
        let (w, h) = (key.width, key.height);
        let tex = |width, height, format, usage, mips| PoolKey::Texture { width, height, format, usage, mips };
        let copy = wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST;
        if key.direct {
            let usage = if mips { copy | wgpu::TextureUsages::STORAGE_BINDING } else { copy };
            return vec![tex(w, h, wgpu::TextureFormat::Rgba8Unorm, usage, mips)];
        }
        let mut keys: Vec<PoolKey> = if key.gpu {
            Vec::new()
        } else {
            (0..key.format.plane_count())
                .map(|p| {
                    let (pw, ph, _) = key.format.plane_dims(p, w, h);
                    tex(pw, ph, plane_format(key.format, p), copy, false)
                })
                .collect()
        };
        let usage = wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING;
        keys.push(tex(w, h, deep_format(deep), usage, mips));
        keys
    }

    /// A slot on `textures`, made for [`InputSlot::pool_keys`] of the same arguments.
    pub fn new(device: &wgpu::Device, conv: &Converter, key: InputKey, deep: bool, mut textures: Vec<wgpu::Texture>) -> Self {
        if key.direct {
            let tex = textures.pop().expect("one texture");
            return InputSlot { key, planes: vec![tex.clone()], texture: tex, uniform: None, bind_group: None, deep };
        }
        let texture = textures.pop().expect("the converted frame");
        let planes = textures;
        let mut slot =
            InputSlot { key, planes, texture, uniform: Some(uniform_buffer(device, "gpufx convert in")), bind_group: None, deep };
        if !key.gpu {
            let planes = slot.planes.clone();
            slot.bind_planes(device, conv, &planes);
        }
        slot
    }

    /// Makes the conversion pass read `planes`.
    fn bind_planes(&mut self, device: &wgpu::Device, conv: &Converter, planes: &[wgpu::Texture]) {
        let buf = self.uniform.as_ref().expect("a conversion pass");
        let dst = self.texture.create_view(&wgpu::TextureViewDescriptor { mip_level_count: Some(1), ..Default::default() });
        let views: Vec<wgpu::TextureView> = planes.iter().map(|t| t.create_view(&Default::default())).collect();
        let mut entries = vec![
            wgpu::BindGroupEntry { binding: 0, resource: buf.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dst) },
        ];
        for i in 0..4 {
            let view = views.get(i).unwrap_or(conv.dummy(self.key.gpu));
            entries.push(wgpu::BindGroupEntry { binding: 2 + i as u32, resource: wgpu::BindingResource::TextureView(view) });
        }
        self.bind_group = Some(device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx convert in"),
            layout: &conv.to_rgba(self.key.gpu, self.deep).1,
            entries: &entries,
        }));
    }

    /// Textures this slot holds: the planes, and the converted frame unless direct.
    pub fn texture_count(&self) -> usize {
        self.planes.len() + self.uniform.is_some() as usize
    }

    /// Bytes of those textures, mip chains included.
    pub fn texture_bytes(&self) -> u64 {
        let size = |t: &wgpu::Texture| {
            let bytes = t.format().block_copy_size(None).unwrap_or(4) as u64;
            let mips = if t.mip_level_count() > 1 { crate::mips::chain_bytes(t.width(), t.height(), bytes) } else { 0 };
            t.width() as u64 * t.height() as u64 * bytes + mips
        };
        self.planes.iter().map(size).sum::<u64>() + if self.uniform.is_some() { size(&self.texture) } else { 0 }
    }

    /// Uploads the planes of a frame matching the key, and its colour info.
    pub fn upload(&self, queue: &wgpu::Queue, planes: &[&[u8]; 4], strides: &[u32; 4], color: &ColorInfo) {
        let (w, h) = (self.key.width, self.key.height);
        for (p, tex) in self.planes.iter().enumerate() {
            let (pw, ph, _) = self.key.format.plane_dims(p, w, h);
            queue.write_texture(
                tex.as_image_copy(),
                planes[p],
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(strides[p]), rows_per_image: Some(ph) },
                wgpu::Extent3d { width: pw, height: ph, depth_or_array_layers: 1 },
            );
        }
        if let Some(buf) = &self.uniform {
            queue.write_buffer(buf, 0, &uniform(self.key.format, w, h, color, None));
        }
    }

    /// Points the conversion pass at the planes of a GPU frame matching the key.
    pub fn use_gpu_frame(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        conv: &Converter,
        planes: &[wgpu::Texture],
        color: &ColorInfo,
    ) {
        self.bind_planes(device, conv, planes);
        self.upload(queue, &[&[]; 4], &[0; 4], color);
    }

    pub fn encode(&self, conv: &Converter, cpass: &mut wgpu::ComputePass) {
        if let Some(bg) = &self.bind_group {
            cpass.set_pipeline(&conv.to_rgba(self.key.gpu, self.deep).0);
            cpass.set_bind_group(0, bg, &[]);
            cpass.dispatch_workgroups(self.key.width.div_ceil(WORKGROUP), self.key.height.div_ceil(WORKGROUP), 1);
        }
    }
}

/// Conversion passes of one output that stays on the GPU: they write the plane textures
/// of the [`crate::GpuFrame`] given with each frame.
pub(crate) struct GpuOutputSlot {
    pub key: (PixelFormat, u32, u32),
    uniforms: Vec<wgpu::Buffer>,
    bind_groups: Vec<wgpu::BindGroup>,
}

impl GpuOutputSlot {
    pub fn new(device: &wgpu::Device, format: PixelFormat, w: u32, h: u32) -> Self {
        let uniforms = (0..format.plane_count()).map(|_| uniform_buffer(device, "gpufx convert out")).collect();
        GpuOutputSlot { key: (format, w, h), uniforms, bind_groups: Vec::new() }
    }

    /// Makes the passes read `source` and write `planes`, with the colours of `color`.
    pub fn bind(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        conv: &Converter,
        source: &wgpu::Texture,
        planes: &[wgpu::Texture],
        color: &ColorInfo,
    ) -> Result<(), Error> {
        let (format, w, h) = self.key;
        let view = source.create_view(&wgpu::TextureViewDescriptor { mip_level_count: Some(1), ..Default::default() });
        self.bind_groups.clear();
        for (i, (buf, plane)) in self.uniforms.iter().zip(planes).enumerate() {
            queue.write_buffer(buf, 0, &uniform(format, w, h, color, Some(i)));
            let dst = plane.create_view(&Default::default());
            self.bind_groups.push(device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("gpufx convert out (gpu)"),
                layout: &conv.to_plane(plane.format())?.1,
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: buf.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&view) },
                    wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&dst) },
                ],
            }));
        }
        Ok(())
    }

    pub fn encode(&self, conv: &Converter, cpass: &mut wgpu::ComputePass) -> Result<(), Error> {
        let (format, w, h) = self.key;
        for (p, bg) in self.bind_groups.iter().enumerate() {
            let (pw, ph) = format.plane_texture_size(p, w, h);
            cpass.set_pipeline(&conv.to_plane(format.plane_texture_format(p))?.0);
            cpass.set_bind_group(0, bg, &[]);
            cpass.dispatch_workgroups(pw.div_ceil(WORKGROUP), ph.div_ceil(WORKGROUP), 1);
        }
        Ok(())
    }
}

struct OutPlane {
    /// Packed words the pass writes: a pooled buffer of `size` bytes, set per frame.
    words: Option<wgpu::Buffer>,
    size: u64,
    uniform: wgpu::Buffer,
    row_words: u32,
    rows: u32,
    row_bytes: u32,
    /// Offset of the plane in the readback buffer.
    offset: u64,
}

/// Conversion passes of one output. Its planes are copied into a readback buffer shared
/// by every output of a graph, at `offset`..`end()`.
pub(crate) struct OutputSlot {
    pub key: (PixelFormat, u32, u32),
    planes: Vec<OutPlane>,
    end: u64,
    /// Bind groups reading the effect output ([0]) and the input texture (bypass, [1]),
    /// both kept so a timeline toggling the filter makes nothing new.
    bind_groups: [Option<Vec<wgpu::BindGroup>>; 2],
}

impl OutputSlot {
    /// `offset`: where the planes start in the shared readback buffer (a multiple of 4).
    pub fn new(device: &wgpu::Device, format: PixelFormat, w: u32, h: u32, mut offset: u64) -> Result<Self, Error> {
        let max = device.limits().max_storage_buffer_binding_size;
        let mut planes = Vec::new();
        for p in 0..format.plane_count() {
            let (row_bytes, rows) = format.plane_size(p, w, h);
            let row_words = row_bytes.div_ceil(4);
            let size = row_words as u64 * 4 * rows as u64;
            if size > max {
                return Err(Error::Frame(format!(
                    "a {w}x{h} {} frame is too large for this GPU: plane {p} needs {size} bytes, the limit is {max}",
                    format.name()
                )));
            }
            planes.push(OutPlane {
                words: None,
                size,
                uniform: uniform_buffer(device, "gpufx convert out"),
                row_words,
                rows,
                row_bytes,
                offset,
            });
            offset += size;
        }
        Ok(OutputSlot { key: (format, w, h), planes, end: offset, bind_groups: [None, None] })
    }

    /// The word buffers of the planes, borrowed from the context pool.
    pub fn pool_keys(&self) -> Vec<PoolKey> {
        let usage = wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC;
        self.planes.iter().map(|p| PoolKey::Buffer { size: p.size, usage }).collect()
    }

    /// Makes the passes write `words` (one per [`OutputSlot::pool_keys`]); they have to
    /// be bound again.
    pub fn set_words(&mut self, words: Vec<wgpu::Buffer>) {
        for (p, b) in self.planes.iter_mut().zip(words) {
            p.words = Some(b);
        }
        self.bind_groups = [None, None];
    }

    /// Drops the bind groups, for a new source texture.
    pub fn unbind(&mut self) {
        self.bind_groups = [None, None];
    }

    /// End of the planes in the readback buffer.
    pub fn end(&self) -> u64 {
        self.end
    }

    pub fn is_bound(&self, input: bool) -> bool {
        self.bind_groups[input as usize].is_some()
    }

    /// Makes the passes read `source`: the RGBA result, or the input when `input`.
    pub fn bind(&mut self, device: &wgpu::Device, conv: &Converter, source: &wgpu::Texture, input: bool) {
        let view = source.create_view(&wgpu::TextureViewDescriptor { mip_level_count: Some(1), ..Default::default() });
        self.bind_groups[input as usize] = Some(
            self.planes
                .iter()
                .map(|p| {
                    device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("gpufx convert out"),
                        layout: &conv.from_rgba_layout,
                        entries: &[
                            wgpu::BindGroupEntry { binding: 0, resource: p.uniform.as_entire_binding() },
                            wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&view) },
                            wgpu::BindGroupEntry {
                                binding: 2,
                                resource: p.words.as_ref().expect("words set before binding").as_entire_binding(),
                            },
                        ],
                    })
                })
                .collect(),
        );
    }

    pub fn encode(&self, queue: &wgpu::Queue, conv: &Converter, cpass: &mut wgpu::ComputePass, color: &ColorInfo, input: bool) {
        let (format, w, h) = self.key;
        let groups = self.bind_groups[input as usize].as_ref().expect("bound before use");
        cpass.set_pipeline(&conv.from_rgba);
        for (i, (p, bg)) in self.planes.iter().zip(groups).enumerate() {
            queue.write_buffer(&p.uniform, 0, &uniform(format, w, h, color, Some(i)));
            cpass.set_bind_group(0, bg, &[]);
            cpass.dispatch_workgroups(p.row_words.div_ceil(WORKGROUP), p.rows.div_ceil(WORKGROUP), 1);
        }
    }

    /// Copies the encoded planes into the shared readback buffer; after the compute pass.
    pub fn copy(&self, enc: &mut wgpu::CommandEncoder, readback: &wgpu::Buffer) {
        for p in &self.planes {
            enc.copy_buffer_to_buffer(p.words.as_ref().expect("words set before use"), 0, readback, p.offset, p.size);
        }
    }

    /// Copies every plane from the mapped readback buffer into `out`.
    fn read(&self, mapped: &[u8], out: &mut FrameMut) {
        for (i, p) in self.planes.iter().enumerate() {
            let (row, stride) = (p.row_bytes as usize, out.strides[i] as usize);
            for y in 0..p.rows as usize {
                let src = &mapped[p.offset as usize + y * p.row_words as usize * 4..][..row];
                out.planes[i][y * stride..][..row].copy_from_slice(src);
            }
        }
    }
}

/// The one mappable buffer every output of a graph is read back through.
pub(crate) fn readback_buffer(device: &wgpu::Device, size: u64) -> wgpu::Buffer {
    device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("gpufx readback"),
        size,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    })
}

/// Waits for the GPU, maps `readback` once and copies every output into its frame.
pub(crate) fn read_outputs(
    device: &wgpu::Device,
    readback: &wgpu::Buffer,
    slots: &[OutputSlot],
    outs: &mut [FrameMut],
) -> Result<(), Error> {
    let slice = readback.slice(..);
    let (tx, rx) = std::sync::mpsc::channel();
    slice.map_async(wgpu::MapMode::Read, move |r| {
        let _ = tx.send(r);
    });
    device.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| Error::Gpu(e.to_string()))?;
    rx.recv().map_err(|e| Error::Gpu(e.to_string()))?.map_err(|e| Error::Gpu(e.to_string()))?;
    {
        let mapped = slice.get_mapped_range().map_err(|e| Error::Gpu(e.to_string()))?;
        for (slot, out) in slots.iter().zip(outs.iter_mut()) {
            slot.read(&mapped, out);
        }
    }
    readback.unmap();
    Ok(())
}
