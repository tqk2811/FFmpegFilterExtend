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

use crate::frame::{ColorInfo, FrameMut, Layout, PixelFormat, PlaneKind};
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

/// Pipelines of the conversion passes, compiled once per device.
pub(crate) struct Converter {
    /// Writing `rgba8unorm` and `rgba16float`.
    to_rgba: [(wgpu::ComputePipeline, wgpu::BindGroupLayout); 2],
    from_rgba: wgpu::ComputePipeline,
    from_rgba_layout: wgpu::BindGroupLayout,
    /// Bound in place of the planes a format does not have.
    dummy: wgpu::TextureView,
}

impl Converter {
    pub fn new(device: &wgpu::Device) -> Self {
        let common = include_str!("convert.wgsl");
        let pipeline = |label: &str, body: &str, entries: &[wgpu::BindGroupLayoutEntry]| {
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
        };
        let entry = |binding, ty| wgpu::BindGroupLayoutEntry { binding, visibility: wgpu::ShaderStages::COMPUTE, ty, count: None };
        let uniform = wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None };
        let texture =
            |sample_type| wgpu::BindingType::Texture { sample_type, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false };
        let plane = texture(wgpu::TextureSampleType::Uint);
        let to_rgba = [false, true].map(|deep| {
            let wgsl = if deep { "rgba16float" } else { "rgba8unorm" };
            pipeline(
                "gpufx convert in",
                &include_str!("convert_in.wgsl").replace("rgba16float", wgsl),
                &[
                    entry(0, uniform),
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
        });
        let (from_rgba, from_rgba_layout) = pipeline(
            "gpufx convert out",
            include_str!("convert_out.wgsl"),
            &[
                entry(0, uniform),
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
        Converter { to_rgba, from_rgba, from_rgba_layout, dummy }
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
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
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
}

/// Upload textures of one input and, unless direct, its conversion pass. Reused from
/// frame to frame while the key holds.
pub(crate) struct InputSlot {
    pub key: InputKey,
    planes: Vec<wgpu::Texture>,
    /// The texture the first effect reads: the RGBA8 plane itself, or the target of the
    /// conversion pass.
    pub texture: wgpu::Texture,
    pass: Option<(wgpu::Buffer, wgpu::BindGroup)>,
    deep: bool,
}

impl InputSlot {
    /// `deep`: convert into `rgba16float` rather than `rgba8unorm`.
    pub fn new(device: &wgpu::Device, conv: &Converter, name: &str, key: InputKey, deep: bool) -> Self {
        let (w, h) = (key.width, key.height);
        let copy = wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST;
        if key.direct {
            let tex = texture_2d(device, name, w, h, wgpu::TextureFormat::Rgba8Unorm, copy);
            return InputSlot { key, planes: vec![tex.clone()], texture: tex, pass: None, deep };
        }
        let planes: Vec<wgpu::Texture> = (0..key.format.plane_count())
            .map(|p| {
                let (pw, ph, _) = key.format.plane_dims(p, w, h);
                texture_2d(device, &format!("{name} plane {p}"), pw, ph, plane_format(key.format, p), copy)
            })
            .collect();
        let texture =
            texture_2d(device, name, w, h, deep_format(deep), wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING);
        let buf = uniform_buffer(device, "gpufx convert in");
        let dst = texture.create_view(&Default::default());
        let views: Vec<wgpu::TextureView> = planes.iter().map(|t| t.create_view(&Default::default())).collect();
        let mut entries = vec![
            wgpu::BindGroupEntry { binding: 0, resource: buf.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dst) },
        ];
        for i in 0..4 {
            let view = views.get(i).unwrap_or(&conv.dummy);
            entries.push(wgpu::BindGroupEntry { binding: 2 + i as u32, resource: wgpu::BindingResource::TextureView(view) });
        }
        let bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("gpufx convert in"),
            layout: &conv.to_rgba[deep as usize].1,
            entries: &entries,
        });
        InputSlot { key, planes, texture, pass: Some((buf, bg)), deep }
    }

    /// Textures this slot holds: the planes, and the converted frame unless direct.
    pub fn texture_count(&self) -> usize {
        self.planes.len() + self.pass.is_some() as usize
    }

    /// Bytes of those textures.
    pub fn texture_bytes(&self) -> u64 {
        let size = |t: &wgpu::Texture| {
            let bytes = t.format().block_copy_size(None).unwrap_or(4) as u64;
            t.width() as u64 * t.height() as u64 * bytes
        };
        self.planes.iter().map(size).sum::<u64>() + if self.pass.is_some() { size(&self.texture) } else { 0 }
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
        if let Some((buf, _)) = &self.pass {
            queue.write_buffer(buf, 0, &uniform(self.key.format, w, h, color, None));
        }
    }

    pub fn encode(&self, conv: &Converter, cpass: &mut wgpu::ComputePass) {
        if let Some((_, bg)) = &self.pass {
            cpass.set_pipeline(&conv.to_rgba[self.deep as usize].0);
            cpass.set_bind_group(0, bg, &[]);
            cpass.dispatch_workgroups(self.key.width.div_ceil(WORKGROUP), self.key.height.div_ceil(WORKGROUP), 1);
        }
    }
}

struct OutPlane {
    /// Packed words the pass writes.
    words: wgpu::Buffer,
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
            let words = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx output plane"),
                size,
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
                mapped_at_creation: false,
            });
            planes.push(OutPlane { words, uniform: uniform_buffer(device, "gpufx convert out"), row_words, rows, row_bytes, offset });
            offset += size;
        }
        Ok(OutputSlot { key: (format, w, h), planes, end: offset, bind_groups: [None, None] })
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
        let view = source.create_view(&Default::default());
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
                            wgpu::BindGroupEntry { binding: 2, resource: p.words.as_entire_binding() },
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
            enc.copy_buffer_to_buffer(&p.words, 0, readback, p.offset, p.words.size());
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
