//! Frames already on the GPU (`EffectGraph::encode_gpu`, the engine behind Vulkan frames):
//! the result must be the same bytes as for the same frames in CPU memory. Skipped when no
//! GPU device can be created.

use std::path::PathBuf;
use std::sync::Arc;

use gpufx_core::{
    Backend, ColorInfo, Effect, EffectGraph, Frame, FrameInfo, FrameMut, GpuContext, GpuFrame, Matrix, Package, PixelFormat, Range,
};

fn gpu() -> Option<Arc<GpuContext>> {
    static CTX: std::sync::OnceLock<Option<Arc<GpuContext>>> = std::sync::OnceLock::new();
    CTX.get_or_init(|| match GpuContext::new(Backend::Auto) {
        Ok(ctx) => Some(ctx),
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    })
    .clone()
}

fn examples() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects")
}

fn graph(ctx: &Arc<GpuContext>, text: &str) -> EffectGraph {
    EffectGraph::parse(text, |path| {
        let fx = Effect::new(ctx.clone(), Package::open(examples().join(path.trim_end_matches(".zip")))?)?;
        Ok((path.trim_end_matches(".zip").to_string(), fx))
    })
    .unwrap()
}

/// Bytes of every plane of a `format` frame, tightly packed, from a smooth pattern.
fn pattern(format: PixelFormat, w: u32, h: u32, seed: u32) -> Vec<Vec<u8>> {
    (0..format.plane_count())
        .map(|p| {
            let (row, rows) = format.plane_size(p, w, h);
            let wide = is_16(format.plane_texture_format(p));
            let mut out = vec![0u8; (row * rows) as usize];
            for y in 0..rows {
                for x in 0..row {
                    out[(y * row + x) as usize] = ((x * 7 + y * 13 + seed * 31 + p as u32 * 50) % 251) as u8;
                }
            }
            if wide && format == PixelFormat::P010 {
                // P010 keeps its samples in the high 10 bits.
                for c in out.chunks_mut(2) {
                    let v = u16::from_le_bytes([c[0], c[1]]) & 0xffc0;
                    c.copy_from_slice(&v.to_le_bytes());
                }
            } else if wide {
                // 10-bit formats keep their samples in the low 10 bits.
                for c in out.chunks_mut(2) {
                    let v = u16::from_le_bytes([c[0], c[1]]) & if format == PixelFormat::Rgba64 { 0xffff } else { 0x03ff };
                    c.copy_from_slice(&v.to_le_bytes());
                }
            }
            out
        })
        .collect()
}

fn is_16(format: wgpu::TextureFormat) -> bool {
    matches!(format, wgpu::TextureFormat::R16Unorm | wgpu::TextureFormat::Rg16Unorm | wgpu::TextureFormat::Rgba16Unorm)
}

fn cpu_run(
    g: &mut EffectGraph,
    inputs: &[(PixelFormat, Vec<Vec<u8>>)],
    outs: &[PixelFormat],
    w: u32,
    h: u32,
    info: Option<&FrameInfo>,
) -> Vec<Vec<Vec<u8>>> {
    let color = ColorInfo { matrix: Matrix::Bt709, range: Range::Limited, ..Default::default() };
    let frames: Vec<Frame> = inputs
        .iter()
        .map(|(format, planes)| {
            let mut p: [&[u8]; 4] = [&[]; 4];
            let mut strides = [0; 4];
            for (i, data) in planes.iter().enumerate() {
                p[i] = data;
                strides[i] = format.plane_size(i, w, h).0;
            }
            Frame { format: *format, width: w, height: h, planes: p, strides, color }
        })
        .collect();
    let mut bufs: Vec<Vec<Vec<u8>>> = outs
        .iter()
        .map(|f| {
            (0..f.plane_count())
                .map(|p| {
                    vec![
                        0u8;
                        {
                            let (r, n) = f.plane_size(p, w, h);
                            (r * n) as usize
                        }
                    ]
                })
                .collect()
        })
        .collect();
    {
        let mut targets: Vec<FrameMut> = bufs
            .iter_mut()
            .zip(outs)
            .map(|(planes, &format)| {
                let mut strides = [0; 4];
                let mut it = planes.iter_mut();
                let mut p: [&mut [u8]; 4] = Default::default();
                for (i, slot) in p.iter_mut().enumerate().take(format.plane_count()) {
                    *slot = it.next().unwrap();
                    strides[i] = format.plane_size(i, w, h).0;
                }
                FrameMut { format, width: w, height: h, planes: p, strides, color }
            })
            .collect();
        match info {
            Some(info) => g.process_frames(&frames, &mut targets, info).unwrap(),
            None => g.convert(&frames, &mut targets).unwrap(),
        }
    }
    bufs
}

fn upload(ctx: &GpuContext, format: PixelFormat, planes: &[Vec<u8>], w: u32, h: u32) -> GpuFrame {
    let color = ColorInfo { matrix: Matrix::Bt709, range: Range::Limited, ..Default::default() };
    let textures = planes
        .iter()
        .enumerate()
        .map(|(p, data)| {
            let (pw, ph) = format.plane_texture_size(p, w, h);
            let tex = ctx.device().create_texture(&wgpu::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d { width: pw, height: ph, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: format.plane_texture_format(p),
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            ctx.queue().write_texture(
                tex.as_image_copy(),
                data,
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(format.plane_size(p, w, h).0), rows_per_image: Some(ph) },
                wgpu::Extent3d { width: pw, height: ph, depth_or_array_layers: 1 },
            );
            tex
        })
        .collect();
    GpuFrame { format, width: w, height: h, planes: textures, color }
}

fn target(ctx: &GpuContext, format: PixelFormat, w: u32, h: u32) -> GpuFrame {
    let color = ColorInfo { matrix: Matrix::Bt709, range: Range::Limited, ..Default::default() };
    let textures = (0..format.plane_count())
        .map(|p| {
            let (pw, ph) = format.plane_texture_size(p, w, h);
            ctx.device().create_texture(&wgpu::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d { width: pw, height: ph, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: format.plane_texture_format(p),
                usage: wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC,
                view_formats: &[],
            })
        })
        .collect();
    GpuFrame { format, width: w, height: h, planes: textures, color }
}

/// Tightly packed bytes of every plane texture.
fn download(ctx: &GpuContext, frame: &GpuFrame) -> Vec<Vec<u8>> {
    let device = ctx.device();
    frame
        .planes
        .iter()
        .enumerate()
        .map(|(p, tex)| {
            let row = frame.format.plane_size(p, frame.width, frame.height).0;
            let padded = row.div_ceil(256) * 256;
            let buf = device.create_buffer(&wgpu::BufferDescriptor {
                label: None,
                size: (padded * tex.height()) as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            });
            let mut enc = device.create_command_encoder(&Default::default());
            enc.copy_texture_to_buffer(
                tex.as_image_copy(),
                wgpu::TexelCopyBufferInfo {
                    buffer: &buf,
                    layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(padded), rows_per_image: None },
                },
                tex.size(),
            );
            ctx.queue().submit([enc.finish()]);
            buf.slice(..).map_async(wgpu::MapMode::Read, |r| r.unwrap());
            device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
            let mapped = buf.slice(..).get_mapped_range().unwrap();
            (0..tex.height() as usize).flat_map(|y| mapped[y * padded as usize..][..row as usize].to_vec()).collect()
        })
        .collect()
}

fn gpu_run(ctx: &GpuContext, g: &mut EffectGraph, inputs: &[GpuFrame], outs: &[GpuFrame], info: Option<&FrameInfo>) -> Vec<Vec<Vec<u8>>> {
    let mut enc = ctx.device().create_command_encoder(&Default::default());
    g.encode_gpu(inputs, outs, info, &mut enc).unwrap();
    ctx.queue().submit([enc.finish()]);
    outs.iter().map(|o| download(ctx, o)).collect()
}

fn supported(ctx: &GpuContext, format: PixelFormat) -> bool {
    let deep = (0..format.plane_count()).any(|p| is_16(format.plane_texture_format(p)));
    let need = wgpu::Features::TEXTURE_ADAPTER_SPECIFIC_FORMAT_FEATURES
        | if deep { wgpu::Features::TEXTURE_FORMAT_16BIT_NORM } else { wgpu::Features::empty() };
    ctx.device().features().contains(need)
}

#[test]
fn gpu_frames_match_cpu_frames() {
    let Some(ctx) = gpu() else { return };
    let (w, h) = (37, 22);
    let info = FrameInfo::new(0.5, 3);
    use PixelFormat::*;
    for (fin, fout) in
        [(Rgba, Rgba), (Nv12, Nv12), (Yuv420p, Rgba), (Rgba, Yuv420p), (P010, Yuv420p10), (Yuva420p, Yuva444p), (Rgba64, P010)]
    {
        if !supported(&ctx, fin) || !supported(&ctx, fout) {
            eprintln!("skipping {} -> {}: the adapter lacks the format features", fin.name(), fout.name());
            continue;
        }
        let data = pattern(fin, w, h, 1);
        let mut g = graph(&ctx, "[0]vignette.zip|grayscale.zip[out]");
        let want = cpu_run(&mut g, &[(fin, data.clone())], &[fout], w, h, Some(&info));
        let input = upload(&ctx, fin, &data, w, h);
        let out = target(&ctx, fout, w, h);
        let got = gpu_run(&ctx, &mut g, &[input], &[out], Some(&info));
        assert_eq!(got, want, "{} -> {}", fin.name(), fout.name());
        // Bypass, as a disabled filter.
        let want = cpu_run(&mut g, &[(fin, data.clone())], &[fout], w, h, None);
        let input = upload(&ctx, fin, &data, w, h);
        let out = target(&ctx, fout, w, h);
        assert_eq!(gpu_run(&ctx, &mut g, &[input], &[out], None), want, "bypass {} -> {}", fin.name(), fout.name());
    }
}

#[test]
fn a_graph_runs_on_gpu_frames_with_pooled_textures() {
    let Some(ctx) = gpu() else { return };
    if !supported(&ctx, PixelFormat::Nv12) {
        return;
    }
    let (w, h) = (40, 24);
    let text = "[0]split[a][b]; [a]gaussian-blur.zip[ba]; [b]grayscale.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[x]; [x][1]wipe-transition.zip[out]";
    let mut g = graph(&ctx, text);
    let a = pattern(PixelFormat::Nv12, w, h, 2);
    let b = pattern(PixelFormat::Rgba, w, h, 3);
    let info = FrameInfo::new(1.0, 1);
    let want = cpu_run(&mut g, &[(PixelFormat::Nv12, a.clone()), (PixelFormat::Rgba, b.clone())], &[PixelFormat::Nv12], w, h, Some(&info));
    let cpu_textures = g.memory().pass_textures;
    let mut allocations = None;
    for _ in 0..3 {
        let ins = [upload(&ctx, PixelFormat::Nv12, &a, w, h), upload(&ctx, PixelFormat::Rgba, &b, w, h)];
        let out = target(&ctx, PixelFormat::Nv12, w, h);
        assert_eq!(gpu_run(&ctx, &mut g, &ins, &[out], Some(&info)), want);
        // New frame textures every call (a pool cycles), nothing new allocated after the first.
        assert_eq!(*allocations.get_or_insert(g.allocations()), g.allocations());
    }
    // Same pooled pass textures as for CPU frames, and no upload planes.
    assert_eq!(g.memory().pass_textures, cpu_textures);
    assert_eq!(g.memory().input_textures, 2, "only the converted frame of each input");
}

#[test]
fn gpu_frames_are_checked() {
    let Some(ctx) = gpu() else { return };
    let mut g = graph(&ctx, "[0]grayscale.zip[out]");
    let input = upload(&ctx, PixelFormat::Rgba, &pattern(PixelFormat::Rgba, 8, 8, 0), 8, 8);
    // An input texture cannot be written.
    let mut enc = ctx.device().create_command_encoder(&Default::default());
    let err =
        g.encode_gpu(std::slice::from_ref(&input), std::slice::from_ref(&input), Some(&FrameInfo::new(0.0, 0)), &mut enc).unwrap_err();
    assert!(err.to_string().contains("STORAGE_BINDING"), "{err}");
    // Wrong plane count.
    let mut nv12 = input.clone();
    nv12.format = PixelFormat::Nv12;
    let out = target(&ctx, PixelFormat::Rgba, 8, 8);
    let err = g.encode_gpu(&[nv12], &[out], Some(&FrameInfo::new(0.0, 0)), &mut enc).unwrap_err();
    assert!(err.to_string().contains("2 plane(s)"), "{err}");
}
