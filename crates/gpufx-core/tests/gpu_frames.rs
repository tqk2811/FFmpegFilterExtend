//! Frames already on the GPU (`EffectGraph::encode_gpu`, the engine behind Vulkan frames):
//! the result must be the same bytes as for the same frames in CPU memory. Skipped when no
//! GPU device can be created.

mod common;

use std::path::PathBuf;
use std::sync::Arc;

use gpufx_core::{ColorInfo, Effect, EffectGraph, Frame, FrameInfo, FrameMut, GpuContext, GpuFrame, Matrix, Package, PixelFormat, Range};

fn gpu() -> Option<Arc<GpuContext>> {
    static CTX: std::sync::OnceLock<Option<Arc<GpuContext>>> = std::sync::OnceLock::new();
    CTX.get_or_init(|| match GpuContext::new(common::backend()) {
        Ok(ctx) => Some(ctx),
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    })
    .clone()
}

/// A device of its own, for tests counting allocations: graphs of other tests share the
/// frame textures of the context pool, and one borrowing a texture right when a graph
/// wants it back makes that graph rebind.
fn own_gpu() -> Option<Arc<GpuContext>> {
    gpu()?;
    GpuContext::new(common::backend()).ok()
}

fn examples() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects")
}

/// Every example effect directory (inside the ffmpeg, slideshow and standalone groups), sorted.
fn example_dirs() -> Vec<PathBuf> {
    let mut all = Vec::new();
    for group in std::fs::read_dir(examples()).unwrap() {
        let group = group.unwrap().path();
        if group.is_dir() {
            all.extend(std::fs::read_dir(group).unwrap().map(|e| e.unwrap().path()).filter(|p| p.join("manifest.json").exists()));
        }
    }
    all.sort();
    all
}

/// The directory of the example effect `name`, whichever group folder it is in.
fn example(name: &str) -> PathBuf {
    example_dirs().into_iter().find(|d| d.file_name().is_some_and(|n| n == name)).unwrap_or_else(|| panic!("no example effect {name}"))
}

fn graph(ctx: &Arc<GpuContext>, text: &str) -> EffectGraph {
    EffectGraph::parse(text, |path| {
        let fx = Effect::new(ctx.clone(), Package::open(example(path.trim_end_matches(".zip")))?)?;
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
    cpu_run_color(g, inputs, outs, w, h, info, color)
}

fn cpu_run_color(
    g: &mut EffectGraph,
    inputs: &[(PixelFormat, Vec<Vec<u8>>)],
    outs: &[PixelFormat],
    w: u32,
    h: u32,
    info: Option<&FrameInfo>,
    color: ColorInfo,
) -> Vec<Vec<Vec<u8>>> {
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
    // Other graphs on the device may use the pooled textures from now on.
    g.release_frame();
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
    let Some(ctx) = own_gpu() else { return };
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
        // New frame textures every call (a pool cycles), nothing new allocated after the
        // first: the context pool hands the graph the same textures back.
        assert_eq!(*allocations.get_or_insert((g.allocations(), ctx.pool_stats().created)), (g.allocations(), ctx.pool_stats().created));
        assert_eq!(ctx.pool_stats().borrowed, 0, "given back by release_frame");
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

/// An effect reading its input through a mip chain (the smallest level), as a package
/// directory removed when dropped.
struct MipPackage(PathBuf);

impl MipPackage {
    fn new() -> Self {
        // One directory per package: tests run in parallel and each removes its own.
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("gpufx-direct-mips-{}-{n}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        let manifest =
            r#"{"api":2,"id":"t.mips","name":"Mips","inputs":[{"name":"src","mipmaps":true}],"passes":[{"shader":"main.wgsl"}]}"#;
        std::fs::write(dir.join("manifest.json"), manifest).unwrap();
        let shader = "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    gpufx_write(id, textureSampleLevel(src, smp, gpufx_uv(id), 20.0));
}";
        std::fs::write(dir.join("main.wgsl"), shader).unwrap();
        MipPackage(dir)
    }
}

impl Drop for MipPackage {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).ok();
    }
}

/// A graph of examples and `mips.zip` (see [`MipPackage`]).
fn graph_with_mips(ctx: &Arc<GpuContext>, text: &str, mips: &MipPackage) -> EffectGraph {
    EffectGraph::parse(text, |path| {
        let name = path.trim_end_matches(".zip");
        let dir = if name == "mips" { mips.0.clone() } else { example(name) };
        Ok((name.to_string(), Effect::new(ctx.clone(), Package::open(dir)?)?))
    })
    .unwrap()
}

/// Runs `text` on GPU frames through the copies and with in-place frames allowed, over
/// three frames of new textures and new content, and checks both write the same bytes.
/// Returns the memory stats of the in-place graph.
fn direct_matches_copies(text: &str, ins: &[PixelFormat], out: PixelFormat, info: Option<&FrameInfo>) -> Option<gpufx_core::MemoryStats> {
    in_place_matches_copies(text, ins, &[out], &[info; 3]).map(|(direct, _)| direct)
}

/// [`direct_matches_copies`] with any outputs and one `info` per frame (`None`: bypassed).
/// Returns the memory stats of the in-place graph and of the copying one.
fn in_place_matches_copies(
    text: &str,
    ins: &[PixelFormat],
    outs: &[PixelFormat],
    infos: &[Option<&FrameInfo>],
) -> Option<(gpufx_core::MemoryStats, gpufx_core::MemoryStats)> {
    let ctx = own_gpu()?;
    if !ins.iter().chain(outs).all(|&f| supported(&ctx, f)) {
        return None;
    }
    let mips = MipPackage::new();
    let (w, h) = (37, 22);
    let mut copied = graph_with_mips(&ctx, text, &mips);
    let mut direct = graph_with_mips(&ctx, text, &mips);
    direct.allow_direct_gpu();
    for (frame, &info) in infos.iter().enumerate() {
        let frame = frame as u32;
        let data: Vec<Vec<Vec<u8>>> = ins.iter().enumerate().map(|(i, &f)| pattern(f, w, h, frame * 5 + i as u32)).collect();
        let upload_all = || ins.iter().zip(&data).map(|(&f, d)| upload(&ctx, f, d, w, h)).collect::<Vec<_>>();
        let targets = || outs.iter().map(|&f| target(&ctx, f, w, h)).collect::<Vec<_>>();
        let want = gpu_run(&ctx, &mut copied, &upload_all(), &targets(), info);
        let got = gpu_run(&ctx, &mut direct, &upload_all(), &targets(), info);
        assert_eq!(got, want, "`{text}`, frame {frame}");
        assert_eq!(ctx.pool_stats().borrowed, 0, "given back by release_frame");
    }
    Some((direct.memory(), copied.memory()))
}

#[test]
fn rgba_gpu_frames_are_read_in_place() {
    use PixelFormat::*;
    let info = FrameInfo::new(0.5, 3);
    // One pass.
    if let Some(m) = direct_matches_copies("[0]grayscale.zip[out]", &[Rgba], Rgba, Some(&info)) {
        assert_eq!(m.input_textures, 0, "no pooled texture for an input read in place");
    }
    // Two effects and a two-pass effect reading the same input.
    if let Some(m) = direct_matches_copies("[0]split[a][b]; [a]gaussian-blur.zip[x]; [x][b]crossfade.zip[out]", &[Rgba], Nv12, Some(&info))
    {
        assert_eq!(m.input_textures, 0);
    }
    // An NV12 input keeps its conversion, the RGBA one is read in place.
    if let Some(m) = direct_matches_copies("[0][1]wipe-transition.zip[out]", &[Nv12, Rgba], Rgba, Some(&info)) {
        assert_eq!(m.input_textures, 1, "only the converted NV12 frame");
    }
    // Bypassed: the output conversion reads the frame.
    if let Some(m) = direct_matches_copies("[0]grayscale.zip[out]", &[Rgba], Nv12, None) {
        assert_eq!(m.input_textures, 0);
    }
}

#[test]
fn rgba_gpu_frames_are_copied_when_they_cannot_be_read_in_place() {
    use PixelFormat::*;
    let info = FrameInfo::new(0.5, 3);
    // A mip chain needs a texture of its own.
    if let Some(m) = direct_matches_copies("[0]mips.zip[out]", &[Rgba], Rgba, Some(&info)) {
        assert_eq!(m.input_textures, 1);
    }
    // A deep graph works in rgba16float.
    if let Some(m) = direct_matches_copies("[0]grayscale.zip[out]", &[Rgba], P010, Some(&info)) {
        assert_eq!(m.input_textures, 1);
    }
}

#[test]
fn rgba_gpu_outputs_are_written_in_place() {
    use PixelFormat::*;
    let info = FrameInfo::new(0.5, 3);
    let on = [Some(&info); 3];
    // One pass: its output is the frame, no pooled texture at all.
    if let Some((direct, copied)) = in_place_matches_copies("[0]grayscale.zip[out]", &[Rgba], &[Rgba], &on) {
        assert_eq!((direct.pass_textures, copied.pass_textures), (0, 1));
    }
    // Two passes: the first keeps its pooled texture, the last writes the frame.
    if let Some((direct, copied)) = in_place_matches_copies("[0]gaussian-blur.zip[out]", &[Nv12], &[Rgba], &on) {
        assert_eq!((direct.pass_textures, copied.pass_textures), (1, 2));
    }
    // Bypassed between two frames: the output conversion comes back, then goes again.
    if let Some((direct, _)) = in_place_matches_copies("[0]grayscale.zip[out]", &[Rgba], &[Rgba], &[Some(&info), None, Some(&info), None]) {
        assert_eq!(direct.pass_textures, 0);
    }
}

#[test]
fn rgba_gpu_outputs_are_copied_when_they_cannot_be_written_in_place() {
    use PixelFormat::*;
    let info = FrameInfo::new(0.5, 3);
    let on = [Some(&info); 3];
    // An output another effect reads: copied; the other output, a vignette, is written in place.
    let text = "[0]grayscale.zip[g]; [g]split[x][y]; [y]vignette.zip[v]";
    if let Some((direct, copied)) = in_place_matches_copies(text, &[Rgba], &[Rgba, Rgba], &on) {
        assert_eq!((direct.pass_textures, copied.pass_textures), (1, 2));
    }
    // An effect written twice (`null` copies nothing): both outputs are converted.
    if let Some((direct, copied)) = in_place_matches_copies("[0]grayscale.zip[g]; [g]split[a][b]", &[Rgba], &[Rgba, Rgba], &on) {
        assert_eq!(direct.pass_textures, copied.pass_textures);
    }
    // Other output formats: deep, or not RGBA.
    for out in [Rgba64, Nv12] {
        if let Some((direct, copied)) = in_place_matches_copies("[0]grayscale.zip[out]", &[Rgba], &[out], &on) {
            assert_eq!(direct.pass_textures, copied.pass_textures, "{}", out.name());
        }
    }
}

/// The YUV conversion passes of GPU frames (one pass writing every output plane, 16x16
/// input tiles sharing their chroma samples) over frames larger than one workgroup, with
/// odd sizes, every chroma siting and range, and several frames: same bytes as the CPU
/// path.
#[test]
fn yuv_gpu_frames_match_cpu_frames_across_tiles() {
    let Some(ctx) = gpu() else { return };
    use gpufx_core::ChromaLocation as L;
    use PixelFormat::*;
    let info = FrameInfo::new(0.5, 3);
    let formats = [Nv12, Yuv420p, Yuv422p, Yuv444p, Yuva420p, Yuva444p, P010, Yuv422p10];
    let mut g = graph(&ctx, "[0]vignette.zip|grayscale.zip[out]");
    // Metal compiles with fast math: a sample landing on a rounding tie may be one step off
    // (seen on p010 -> yuv422p10 chroma). Other backends must match byte for byte.
    let metal = ctx.description().ends_with("(Metal)");
    for (n, (fin, fout)) in formats.iter().zip(formats.iter().cycle().skip(1)).chain(formats.iter().zip(formats.iter())).enumerate() {
        let (fin, fout) = (*fin, *fout);
        if !supported(&ctx, fin) || !supported(&ctx, fout) {
            eprintln!("skipping {} -> {}: the adapter lacks the format features", fin.name(), fout.name());
            continue;
        }
        let loc = [L::Left, L::Center, L::TopLeft, L::Top, L::BottomLeft, L::Bottom][n % 6];
        let range = if n % 2 == 0 { Range::Limited } else { Range::Full };
        let color = ColorInfo { matrix: Matrix::Bt709, range, chroma_location: loc, ..Default::default() };
        let (w, h) = [(70, 45), (33, 17), (49, 50)][n % 3];
        for seed in 0..3 {
            let data = pattern(fin, w, h, seed + n as u32);
            for info in [Some(&info), None] {
                let want = cpu_run_color(&mut g, &[(fin, data.clone())], &[fout], w, h, info, color);
                let mut input = upload(&ctx, fin, &data, w, h);
                input.color = color;
                let mut out = target(&ctx, fout, w, h);
                out.color = color;
                let got = gpu_run(&ctx, &mut g, &[input], &[out], info);
                let what = format!("{} -> {} {w}x{h} {loc:?} {range:?} seed {seed} bypass {}", fin.name(), fout.name(), info.is_none());
                if metal {
                    assert_samples_near(&got, &want, fout, &what);
                } else {
                    assert_eq!(got, want, "{what}");
                }
            }
        }
    }
}

/// Same planes, every sample at most one step apart (2-byte little-endian samples for the
/// 10-bit formats, bytes otherwise).
fn assert_samples_near(got: &[Vec<Vec<u8>>], want: &[Vec<Vec<u8>>], format: PixelFormat, what: &str) {
    let wide = matches!(format, PixelFormat::P010 | PixelFormat::Yuv422p10);
    assert_eq!(got.len(), want.len(), "{what}");
    for (f, (gf, wf)) in got.iter().zip(want).enumerate() {
        assert_eq!(gf.len(), wf.len(), "{what}");
        for (p, (gp, wp)) in gf.iter().zip(wf).enumerate() {
            assert_eq!(gp.len(), wp.len(), "{what} plane {p}");
            let samples = |b: &[u8]| -> Vec<i32> {
                if wide {
                    b.as_chunks::<2>().0.iter().map(|&c| u16::from_le_bytes(c) as i32).collect()
                } else {
                    b.iter().map(|&v| v as i32).collect()
                }
            };
            for (i, (a, b)) in samples(gp).into_iter().zip(samples(wp)).enumerate() {
                assert!((a - b).abs() <= 1, "{what}: output {f} plane {p} sample {i}: {a} vs {b}");
            }
        }
    }
}

/// Frames of a pool come back in turn: the bindings made for their textures (conversion
/// passes, effects reading or writing them in place) are made once per texture set, and
/// the results stay those of a graph binding everything anew (new textures each frame).
#[test]
fn bindings_of_pooled_gpu_frames_are_made_once() {
    use PixelFormat::*;
    let info = FrameInfo::new(0.5, 3);
    for (text, fin, fout, direct) in [
        ("[0]vignette.zip|grayscale.zip[out]", Nv12, Nv12, false),
        ("[0]vignette.zip|grayscale.zip[out]", Rgba, Rgba, true),
        ("[0]split[a][b]; [a]gaussian-blur.zip[x]; [x][b]crossfade.zip[out]", Rgba, Yuv420p, true),
    ] {
        let Some(ctx) = own_gpu() else { return };
        if !supported(&ctx, fin) || !supported(&ctx, fout) {
            continue;
        }
        let (w, h) = (37, 22);
        let mut pooled = graph(&ctx, text);
        let mut fresh = graph(&ctx, text);
        if direct {
            pooled.allow_direct_gpu();
            fresh.allow_direct_gpu();
        }
        // A pool of three frames on each side, used in turn.
        let pool_in: Vec<GpuFrame> = (0..3).map(|_| upload(&ctx, fin, &pattern(fin, w, h, 0), w, h)).collect();
        let pool_out: Vec<GpuFrame> = (0..3).map(|_| target(&ctx, fout, w, h)).collect();
        let mut after_first_round = 0;
        for frame in 0..9u32 {
            let data = pattern(fin, w, h, frame);
            let k = frame as usize % 3;
            // New content in the pooled texture, as FFmpeg would upload it.
            for (p, tex) in pool_in[k].planes.iter().enumerate() {
                let (pw, ph) = fin.plane_texture_size(p, w, h);
                ctx.queue().write_texture(
                    tex.as_image_copy(),
                    &data[p],
                    wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(fin.plane_size(p, w, h).0), rows_per_image: Some(ph) },
                    wgpu::Extent3d { width: pw, height: ph, depth_or_array_layers: 1 },
                );
            }
            let info = if frame == 4 { None } else { Some(&info) };
            let got = gpu_run(&ctx, &mut pooled, &[pool_in[k].clone()], &[pool_out[k].clone()], info);
            let want = gpu_run(&ctx, &mut fresh, &[upload(&ctx, fin, &data, w, h)], &[target(&ctx, fout, w, h)], info);
            assert_eq!(got, want, "`{text}` {} -> {}, frame {frame}", fin.name(), fout.name());
            if frame == 5 {
                after_first_round = pooled.frame_binds();
            }
        }
        assert!(after_first_round > 0, "`{text}`: frames are bound");
        assert_eq!(pooled.frame_binds(), after_first_round, "`{text}`: no binding made once every pooled frame was seen");
        assert!(fresh.frame_binds() > after_first_round, "`{text}`: new textures are bound anew");
    }
}

#[test]
fn effects_switched_off_write_their_copy_in_place() {
    use PixelFormat::*;
    let Some(ctx) = own_gpu() else { return };
    let info = FrameInfo::new(0.5, 3);
    let mips = MipPackage::new();
    let (w, h) = (37, 22);
    // The copy of a switched-off effect writes the output frame itself, with one pass or two.
    for (text, node) in [("[0]grayscale.zip[out]", "grayscale"), ("[0]invert.zip|gaussian-blur.zip[out]", "gaussian-blur")] {
        let mut copied = graph_with_mips(&ctx, text, &mips);
        let mut direct = graph_with_mips(&ctx, text, &mips);
        direct.allow_direct_gpu();
        for frame in 0..4u32 {
            // Off, on, off, on: the frames change and so does the copy.
            let on = frame % 2 == 1;
            for g in [&mut copied, &mut direct] {
                for k in g.find_node(node).unwrap() {
                    g.set_node_enabled(k, on).unwrap();
                }
            }
            let data = pattern(Rgba, w, h, frame);
            let want = gpu_run(&ctx, &mut copied, &[upload(&ctx, Rgba, &data, w, h)], &[target(&ctx, Rgba, w, h)], Some(&info));
            let got = gpu_run(&ctx, &mut direct, &[upload(&ctx, Rgba, &data, w, h)], &[target(&ctx, Rgba, w, h)], Some(&info));
            assert_eq!(got, want, "`{text}`, frame {frame}");
            if text.starts_with("[0]grayscale") && !on {
                assert_eq!(got[0], data, "off is the input");
            }
        }
    }
}

#[test]
fn bypass_picks_the_input_passed_on_gpu_frames() {
    use PixelFormat::*;
    let Some(ctx) = own_gpu() else { return };
    let info = FrameInfo::new(0.5, 3);
    let (w, h) = (37, 22);
    let a = pattern(Rgba, w, h, 1);
    let b = pattern(Rgba, w, h, 2);
    let ins = || [upload(&ctx, Rgba, &a, w, h), upload(&ctx, Rgba, &b, w, h)];

    // A transition switched off after its end passes its second input, in place too.
    for direct in [false, true] {
        let mut g = graph(&ctx, "[0][1]crossfade.zip[out]");
        if direct {
            g.allow_direct_gpu();
        }
        g.set_node_enabled(0, false).unwrap();
        assert_eq!(gpu_run(&ctx, &mut g, &ins(), &[target(&ctx, Rgba, w, h)], Some(&info))[0], a, "direct {direct}");
        g.set_node_bypass(0, 1).unwrap();
        assert_eq!(gpu_run(&ctx, &mut g, &ins(), &[target(&ctx, Rgba, w, h)], Some(&info))[0], b, "direct {direct}");
    }

    // The graph bypassed (the filter disabled): the pad picked, or the one the effects lead to.
    let mut g = graph(&ctx, "[0][1]crossfade.zip[out]");
    assert_eq!(gpu_run(&ctx, &mut g, &ins(), &[target(&ctx, Rgba, w, h)], None)[0], a);
    g.set_bypass_pad(gpufx_core::BypassPad::Pad(1)).unwrap();
    assert_eq!(gpu_run(&ctx, &mut g, &ins(), &[target(&ctx, Rgba, w, h)], None)[0], b, "the output rebinds to pad 1");
    g.set_bypass_pad(gpufx_core::BypassPad::Nodes).unwrap();
    assert_eq!(gpu_run(&ctx, &mut g, &ins(), &[target(&ctx, Rgba, w, h)], None)[0], a);
    g.set_node_bypass(0, 1).unwrap();
    assert_eq!(gpu_run(&ctx, &mut g, &ins(), &[target(&ctx, Rgba, w, h)], None)[0], b);

    // An input of another size than the output: an error, not another input.
    let small = pattern(Rgba, 16, 8, 3);
    let ins = [upload(&ctx, Rgba, &a, w, h), upload(&ctx, Rgba, &small, 16, 8)];
    let mut g = graph(&ctx, "[0][1]overlay.zip[out]");
    g.set_node_enabled(0, false).unwrap();
    g.set_node_bypass(0, 1).unwrap();
    let mut enc = ctx.device().create_command_encoder(&Default::default());
    let err = g.encode_gpu(&ins, &[target(&ctx, Rgba, w, h)], Some(&info), &mut enc).unwrap_err().to_string();
    assert!(err.contains("passes its input 1") && err.contains("16x8"), "{err}");
    g.set_bypass_pad(gpufx_core::BypassPad::Pad(1)).unwrap();
    let err = g.encode_gpu(&ins, &[target(&ctx, Rgba, w, h)], None, &mut enc).unwrap_err().to_string();
    assert!(err.contains("bypass passes input 1") && err.contains("16x8"), "{err}");
}
