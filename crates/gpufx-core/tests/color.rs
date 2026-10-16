//! YUV <-> RGBA conversion on the GPU: round trips, colour matrices, ranges, 10-bit
//! precision and premultiplied alpha. Skipped when no GPU device can be created.

mod common;

use std::path::PathBuf;

use gpufx_core::{
    ChromaLocation, ColorInfo, Effect, EffectChain, Frame, FrameInfo, FrameMut, GpuContext, Matrix, Package, PixelFormat, Range,
};

fn gpu() -> Option<std::sync::Arc<GpuContext>> {
    static CTX: std::sync::OnceLock<Option<std::sync::Arc<GpuContext>>> = std::sync::OnceLock::new();
    CTX.get_or_init(|| match GpuContext::new(common::backend()) {
        Ok(ctx) => Some(ctx),
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    })
    .clone()
}

/// An effect that copies its input; its package lives in a temporary directory.
fn identity(ctx: &std::sync::Arc<GpuContext>, tag: &str) -> Effect {
    let dir = std::env::temp_dir().join(format!("gpufx-identity-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("shaders")).unwrap();
    std::fs::write(dir.join("manifest.json"), r#"{"id":"t.identity","name":"Identity","passes":[{"shader":"shaders/main.wgsl"}]}"#)
        .unwrap();
    std::fs::write(
        dir.join("shaders/main.wgsl"),
        "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) { if (gpufx_in_bounds(id)) { gpufx_write(id, textureLoad(src, vec2i(id.xy), 0)); } }",
    )
    .unwrap();
    let fx = Effect::new(ctx.clone(), Package::open(&dir).unwrap()).unwrap();
    std::fs::remove_dir_all(&dir).ok();
    fx
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

fn kr_kb(m: Matrix) -> (f64, f64) {
    match m {
        Matrix::Bt601 => (0.299, 0.114),
        Matrix::Bt709 => (0.2126, 0.0722),
        Matrix::Bt2020 => (0.2627, 0.0593),
    }
}

/// Reference RGB (0..1) -> Y, U, V sample values (unrounded) for `depth` bits.
fn encode(rgb: [f64; 3], color: &ColorInfo, depth: u32) -> [f64; 3] {
    let (kr, kb) = kr_kb(color.matrix);
    let y = kr * rgb[0] + (1.0 - kr - kb) * rgb[1] + kb * rgb[2];
    let u = (rgb[2] - y) / (2.0 * (1.0 - kb));
    let v = (rgb[0] - y) / (2.0 * (1.0 - kr));
    let max = ((1u32 << depth) - 1) as f64;
    let s = (1u32 << (depth - 8)) as f64;
    match color.range {
        Range::Full => [y * max, u * max + (1u32 << (depth - 1)) as f64, v * max + (1u32 << (depth - 1)) as f64],
        Range::Limited => [(y * 219.0 + 16.0) * s, (u * 224.0 + 128.0) * s, (v * 224.0 + 128.0) * s],
    }
}

fn depth_shift(format: PixelFormat) -> (u32, u32) {
    match format {
        PixelFormat::P010 => (10, 6),
        PixelFormat::Yuv420p10 | PixelFormat::Yuv422p10 | PixelFormat::Yuv444p10 => (10, 0),
        PixelFormat::Rgba64 => (16, 0),
        _ => (8, 0),
    }
}

fn subsampling(format: PixelFormat) -> (u32, u32) {
    use PixelFormat::*;
    match format {
        Nv12 | P010 | Yuv420p | Yuv420p10 | Yuva420p => (2, 2),
        Yuv422p | Yuv422p10 => (2, 1),
        _ => (1, 1),
    }
}

/// Planes of a frame, as sample values (one Vec per plane, interleaved channels).
#[derive(Debug, Clone, PartialEq)]
struct Planes {
    format: PixelFormat,
    w: u32,
    h: u32,
    values: Vec<Vec<u32>>,
}

impl Planes {
    /// A YUV frame of the picture `rgba(x, y)` (pixel coordinates), each chroma sample
    /// taken where `color.chroma_location` puts it.
    fn from_rgba(format: PixelFormat, w: u32, h: u32, color: &ColorInfo, rgba: impl Fn(f64, f64) -> [f64; 4]) -> Self {
        let (depth, _) = depth_shift(format);
        let (sx, sy) = subsampling(format);
        let (cw, ch) = (w.div_ceil(sx), h.div_ceil(sy));
        let yuv = |x: f64, y: f64| {
            let c = rgba(x, y);
            encode([c[0], c[1], c[2]], color, depth)
        };
        let luma: Vec<u32> = (0..w * h).map(|i| yuv((i % w) as f64, (i / w) as f64)[0].round() as u32).collect();
        let (site_x, site_y) = match color.chroma_location {
            ChromaLocation::Left => (0.0, 0.5),
            ChromaLocation::Center => (0.5, 0.5),
            ChromaLocation::TopLeft => (0.0, 0.0),
            ChromaLocation::Top => (0.5, 0.0),
            ChromaLocation::BottomLeft => (0.0, 1.0),
            ChromaLocation::Bottom => (0.5, 1.0),
        };
        let mut u = Vec::new();
        let mut v = Vec::new();
        for cy in 0..ch {
            for cx in 0..cw {
                let x = (sx * cx) as f64 + site_x * (sx - 1) as f64;
                let y = (sy * cy) as f64 + site_y * (sy - 1) as f64;
                let s = yuv(x, y);
                u.push(s[1].round() as u32);
                v.push(s[2].round() as u32);
            }
        }
        let max = ((1u32 << depth) - 1) as f64;
        let alpha: Vec<u32> = (0..w * h).map(|i| (rgba((i % w) as f64, (i / w) as f64)[3] * max).round() as u32).collect();
        let values = match format {
            PixelFormat::Nv12 | PixelFormat::P010 => vec![luma, u.iter().zip(&v).flat_map(|(&a, &b)| [a, b]).collect()],
            PixelFormat::Yuva420p | PixelFormat::Yuva444p => vec![luma, u, v, alpha],
            _ => vec![luma, u, v],
        };
        Planes { format, w, h, values }
    }

    fn empty(format: PixelFormat, w: u32, h: u32) -> Self {
        let values = (0..format.plane_count())
            .map(|p| {
                let (row, rows) = format.plane_size(p, w, h);
                let bytes = if depth_shift(format).0 > 8 { 2 } else { 1 };
                vec![0; (row / bytes * rows) as usize]
            })
            .collect();
        Planes { format, w, h, values }
    }

    /// Stored bytes of every plane, rows padded by `pad` bytes.
    fn bytes(&self, pad: u32) -> (Vec<Vec<u8>>, [u32; 4]) {
        let (depth, shift) = depth_shift(self.format);
        let mut strides = [0; 4];
        let planes = self
            .values
            .iter()
            .enumerate()
            .map(|(p, vals)| {
                let (row, rows) = self.format.plane_size(p, self.w, self.h);
                strides[p] = row + pad;
                let mut out = vec![0u8; ((row + pad) * rows) as usize];
                let per_row = vals.len() / rows as usize;
                for (i, &v) in vals.iter().enumerate() {
                    let at = i / per_row * (row + pad) as usize;
                    if depth > 8 {
                        out[at + i % per_row * 2..][..2].copy_from_slice(&((v << shift) as u16).to_le_bytes());
                    } else {
                        out[at + i % per_row] = v as u8;
                    }
                }
                out
            })
            .collect();
        (planes, strides)
    }

    fn from_bytes(format: PixelFormat, w: u32, h: u32, planes: &[Vec<u8>], strides: [u32; 4]) -> Self {
        let (depth, shift) = depth_shift(format);
        let values = planes
            .iter()
            .enumerate()
            .map(|(p, data)| {
                let (row, rows) = format.plane_size(p, w, h);
                (0..rows as usize)
                    .flat_map(|y| {
                        let line = &data[y * strides[p] as usize..][..row as usize];
                        if depth > 8 {
                            line.chunks(2).map(|c| (u16::from_le_bytes([c[0], c[1]]) >> shift) as u32).collect::<Vec<_>>()
                        } else {
                            line.iter().map(|&b| b as u32).collect()
                        }
                    })
                    .collect()
            })
            .collect();
        Planes { format, w, h, values }
    }

    /// Largest difference per plane, leaving out the `border` outer samples (where a
    /// chroma filter sees the edge).
    fn max_diff(&self, other: &Planes, border: u32) -> Vec<u32> {
        (0..self.values.len())
            .map(|p| {
                let (pw, ph, channels) = plane_dims(self.format, p, self.w, self.h);
                let mut worst = 0;
                for y in border..ph.saturating_sub(border) {
                    for x in border * channels..(pw * channels).saturating_sub(border * channels) {
                        let i = (y * pw * channels + x) as usize;
                        worst = worst.max(self.values[p][i].abs_diff(other.values[p][i]));
                    }
                }
                worst
            })
            .collect()
    }
}

/// Samples per row, rows and channels of a plane.
fn plane_dims(format: PixelFormat, p: usize, w: u32, h: u32) -> (u32, u32, u32) {
    let (row, rows) = format.plane_size(p, w, h);
    let bytes = if depth_shift(format).0 > 8 { 2 } else { 1 };
    let channels = match (format, p) {
        (PixelFormat::Rgba | PixelFormat::Rgba64, _) => 4,
        (PixelFormat::Nv12 | PixelFormat::P010, 1) => 2,
        _ => 1,
    };
    (row / bytes / channels, rows, channels)
}

fn as_frame<'a>(planes: &'a [Vec<u8>], strides: [u32; 4], format: PixelFormat, w: u32, h: u32, color: ColorInfo) -> Frame<'a> {
    let mut p: [&[u8]; 4] = [&[]; 4];
    for (i, data) in planes.iter().enumerate() {
        p[i] = data;
    }
    Frame { format, width: w, height: h, planes: p, strides, color }
}

/// Runs `fx` on one frame and returns the output in `out_format`.
fn run(fx: &mut Effect, input: &Planes, color: ColorInfo, out_format: PixelFormat, out_color: ColorInfo) -> Planes {
    let (w, h) = (input.w, input.h);
    let (data, strides) = input.bytes(3);
    let frame = as_frame(&data, strides, input.format, w, h, color);
    let (mut out, out_strides) = Planes::empty(out_format, w, h).bytes(5);
    {
        let mut planes: Vec<&mut [u8]> = out.iter_mut().map(|v| v.as_mut_slice()).collect();
        planes.resize_with(4, Default::default);
        let mut it = planes.into_iter();
        let target = FrameMut {
            format: out_format,
            width: w,
            height: h,
            planes: [it.next().unwrap(), it.next().unwrap(), it.next().unwrap(), it.next().unwrap()],
            strides: out_strides,
            color: out_color,
        };
        fx.process_frames(&[frame], target, &FrameInfo::new(0.0, 0)).unwrap();
    }
    Planes::from_bytes(out_format, w, h, &out, out_strides)
}

fn smooth(w: u32, h: u32) -> impl Fn(f64, f64) -> [f64; 4] {
    move |x, y| {
        let (fx, fy) = (x / w as f64, y / h as f64);
        [0.1 + 0.8 * fx, 0.2 + 0.6 * fy, 0.9 - 0.7 * (fx + fy) / 2.0, 1.0]
    }
}

#[test]
fn yuv_round_trips_through_an_identity_effect() {
    let Some(ctx) = gpu() else { return };
    let mut fx = identity(&ctx, "round-trip");
    let (w, h) = (67, 41); // odd on purpose: chroma planes round up
    let colors = [
        ColorInfo { matrix: Matrix::Bt709, range: Range::Limited, ..Default::default() },
        ColorInfo { matrix: Matrix::Bt601, range: Range::Full, chroma_location: ChromaLocation::Center, ..Default::default() },
        ColorInfo { matrix: Matrix::Bt2020, range: Range::Limited, chroma_location: ChromaLocation::TopLeft, ..Default::default() },
    ];
    use PixelFormat::*;
    for format in [Nv12, P010, Yuv420p, Yuv420p10, Yuv422p, Yuv422p10, Yuv444p, Yuv444p10, Yuva420p, Yuva444p] {
        for color in colors {
            let src = Planes::from_rgba(format, w, h, &color, |x, y| {
                let c = smooth(w, h)(x, y);
                [c[0], c[1], c[2], if format.has_alpha() { (x as u32 % 7) as f64 / 6.0 } else { 1.0 }]
            });
            let out = run(&mut fx, &src, color, format, color);
            // Inside, at most one code of rounding. On the edges the chroma filters see
            // repeated pixels, which a gradient does not have: a few 10-bit codes.
            let inner = src.max_diff(&out, 1);
            assert!(inner.iter().all(|&d| d <= 1), "{format:?} {color:?}: differences {inner:?}");
            let edges = src.max_diff(&out, 0);
            let tol = if depth_shift(format).0 > 8 { 10 } else { 2 };
            assert!(edges.iter().all(|&d| d <= tol), "{format:?} {color:?}: differences on the edges {edges:?}");

            // The RGBA the effect saw is the picture itself.
            let rgba = run(&mut fx, &src, color, Rgba, ColorInfo::default());
            let want = smooth(w, h);
            let mut worst = 0.0f64;
            for (i, px) in rgba.values[0].chunks(4).enumerate() {
                let c = want((i as u32 % w) as f64, (i as u32 / w) as f64);
                for k in 0..3 {
                    worst = worst.max((px[k] as f64 - c[k] * 255.0).abs());
                }
            }
            assert!(worst <= 4.0, "{format:?} {color:?}: RGBA off by {worst}");
        }
    }
}

/// One w x h yuv420p frame of a single colour.
fn flat(format: PixelFormat, y: u32, u: u32, v: u32) -> Planes {
    let mut p = Planes::empty(format, 4, 4);
    p.values[0].fill(y);
    if p.values.len() == 2 {
        for (i, s) in p.values[1].iter_mut().enumerate() {
            *s = if i % 2 == 0 { u } else { v };
        }
    } else {
        p.values[1].fill(u);
        p.values[2].fill(v);
    }
    p
}

#[test]
fn decoding_follows_matrix_and_range() {
    let Some(ctx) = gpu() else { return };
    let mut fx = identity(&ctx, "decode");
    let rgba = |fx: &mut Effect, p: &Planes, matrix, range| {
        let out = run(fx, p, ColorInfo { matrix, range, ..Default::default() }, PixelFormat::Rgba, ColorInfo::default());
        [out.values[0][0], out.values[0][1], out.values[0][2], out.values[0][3]]
    };
    let close = |a: [u32; 4], b: [u32; 4]| a.iter().zip(&b).all(|(x, y)| x.abs_diff(*y) <= 1);
    // BT.709 limited red.
    let red = flat(PixelFormat::Yuv420p, 63, 102, 240);
    let got = rgba(&mut fx, &red, Matrix::Bt709, Range::Limited);
    assert!(close(got, [255, 0, 0, 255]), "{got:?}");
    // Read as BT.601 it is another colour.
    let got = rgba(&mut fx, &red, Matrix::Bt601, Range::Limited);
    assert!(got[0] < 240, "{got:?}");
    // The same in 10 bits, NV12 layout and P010.
    let got = rgba(&mut fx, &flat(PixelFormat::P010, 250, 409, 960), Matrix::Bt709, Range::Limited);
    assert!(close(got, [255, 0, 0, 255]), "{got:?}");
    let got = rgba(&mut fx, &flat(PixelFormat::Nv12, 63, 102, 240), Matrix::Bt709, Range::Limited);
    assert!(close(got, [255, 0, 0, 255]), "{got:?}");
    // Limited range white and black are full range grays.
    let white = flat(PixelFormat::Yuv420p, 235, 128, 128);
    assert_eq!(rgba(&mut fx, &white, Matrix::Bt709, Range::Limited), [255, 255, 255, 255]);
    assert_eq!(rgba(&mut fx, &white, Matrix::Bt709, Range::Full), [235, 235, 235, 255]);
    let black = flat(PixelFormat::Yuv420p10, 64, 512, 512);
    assert_eq!(rgba(&mut fx, &black, Matrix::Bt2020, Range::Limited), [0, 0, 0, 255]);
    assert_eq!(rgba(&mut fx, &black, Matrix::Bt2020, Range::Full), [16, 16, 16, 255]);
}

#[test]
fn encoding_follows_matrix_and_range() {
    let Some(ctx) = gpu() else { return };
    let mut fx = identity(&ctx, "encode");
    let mut red = Planes::empty(PixelFormat::Rgba, 4, 4);
    for px in red.values[0].chunks_mut(4) {
        px.copy_from_slice(&[255, 0, 0, 255]);
    }
    let mut yuv = |format, matrix, range| {
        let out = run(&mut fx, &red, ColorInfo::default(), format, ColorInfo { matrix, range, ..Default::default() });
        out.values.iter().map(|p| p[0]).collect::<Vec<_>>()
    };
    assert_eq!(yuv(PixelFormat::Yuv420p, Matrix::Bt709, Range::Limited), [63, 102, 240]);
    assert_eq!(yuv(PixelFormat::Yuv420p, Matrix::Bt601, Range::Limited), [81, 90, 240]);
    assert_eq!(yuv(PixelFormat::Yuv420p, Matrix::Bt601, Range::Full), [76, 85, 255]);
    assert_eq!(yuv(PixelFormat::Nv12, Matrix::Bt709, Range::Limited), [63, 102]);
    assert_eq!(yuv(PixelFormat::P010, Matrix::Bt709, Range::Limited), [250, 409]);
    assert_eq!(yuv(PixelFormat::Yuv420p10, Matrix::Bt709, Range::Full), [217, 395, 1023]);
}

#[test]
fn ten_bit_steps_survive_a_chain() {
    let Some(ctx) = gpu() else { return };
    let mut chain = EffectChain::new(vec![("a".into(), identity(&ctx, "chain-a")), ("b".into(), identity(&ctx, "chain-b"))]).unwrap();
    // Every 10-bit luma code from black to white, two pixels each: 8 bits would merge
    // groups of four.
    let (w, h) = (64, 28);
    let mut src = Planes::empty(PixelFormat::P010, w, h);
    for (i, y) in src.values[0].iter_mut().enumerate() {
        *y = (64 + i / 2).min(940) as u32;
    }
    src.values[1].fill(512);
    let color = ColorInfo { matrix: Matrix::Bt2020, ..Default::default() };
    let (data, strides) = src.bytes(0);
    let (mut out, out_strides) = Planes::empty(PixelFormat::P010, w, h).bytes(0);
    {
        let (y, uv) = out.split_at_mut(1);
        let target = FrameMut {
            format: PixelFormat::P010,
            width: w,
            height: h,
            planes: [&mut y[0], &mut uv[0], &mut [], &mut []],
            strides: out_strides,
            color,
        };
        chain.process_frames(&[as_frame(&data, strides, PixelFormat::P010, w, h, color)], target, &FrameInfo::new(0.0, 0)).unwrap();
    }
    let got = Planes::from_bytes(PixelFormat::P010, w, h, &out, out_strides);
    let diff = src.max_diff(&got, 0);
    assert!(diff[0] <= 1 && diff[1] <= 1, "{diff:?}");
}

#[test]
fn premultiplied_frames_reach_effects_straight() {
    let Some(ctx) = gpu() else { return };
    let mut fx = identity(&ctx, "premul");
    // 16-bit premultiplied RGBA: a quarter grey at half alpha is a half grey.
    let mut src = Planes::empty(PixelFormat::Rgba64, 4, 4);
    for px in src.values[0].chunks_mut(4) {
        px.copy_from_slice(&[16384, 16384, 16384, 32768]);
    }
    let premul = ColorInfo { premultiplied: true, ..Default::default() };
    let straight = run(&mut fx, &src, premul, PixelFormat::Rgba, ColorInfo::default());
    assert_eq!(straight.values[0][..4], [128, 128, 128, 128]);
    // And back to premultiplied on output.
    let again = run(&mut fx, &src, premul, PixelFormat::Rgba64, premul);
    assert!(again.values[0][..4].iter().zip(&src.values[0][..4]).all(|(a, b)| a.abs_diff(*b) <= 16), "{:?}", &again.values[0][..4]);
}

#[test]
fn convert_bypasses_the_effects() {
    let Some(ctx) = gpu() else { return };
    let invert = Effect::new(ctx.clone(), Package::open(example("invert")).unwrap()).unwrap();
    let mut chain = EffectChain::new(vec![("invert".into(), invert)]).unwrap();
    let color = ColorInfo { matrix: Matrix::Bt709, ..Default::default() };
    let src = flat(PixelFormat::Nv12, 235, 128, 128);
    let (data, strides) = src.bytes(0);
    let mut out = vec![0u8; 4 * 4 * 4];
    let frame = as_frame(&data, strides, PixelFormat::Nv12, 4, 4, color);
    fn target(out: &mut [u8]) -> FrameMut<'_> {
        FrameMut {
            format: PixelFormat::Rgba,
            width: 4,
            height: 4,
            planes: [out, &mut [], &mut [], &mut []],
            strides: [16, 0, 0, 0],
            color: ColorInfo::default(),
        }
    }
    chain.convert(&frame, target(&mut out)).unwrap();
    assert_eq!(out[..4], [255, 255, 255, 255]);
    chain.process_frames(&[frame], target(&mut out), &FrameInfo::new(0.0, 0)).unwrap();
    assert_eq!(out[..4], [0, 0, 0, 255]);
    chain.convert(&frame, target(&mut out)).unwrap();
    assert_eq!(out[..4], [255, 255, 255, 255]);
}

#[test]
fn toggling_the_effects_reuses_every_resource() {
    // A device of its own: the buffer pool lives in the context, and another test running
    // in parallel may hold the buffers this chain borrowed last time, which makes it take
    // others and bind them again, counted as allocations.
    if gpu().is_none() {
        return;
    }
    let Ok(ctx) = GpuContext::new(common::backend()) else { return };
    let crossfade = Effect::new(ctx.clone(), Package::open(example("crossfade")).unwrap()).unwrap();
    let mut chain = EffectChain::new(vec![("crossfade".into(), crossfade), ("b".into(), identity(&ctx, "toggle"))]).unwrap();
    let color = ColorInfo { matrix: Matrix::Bt709, ..Default::default() };
    let first = flat(PixelFormat::P010, 250, 409, 960);
    let (a, a_strides) = first.bytes(0);
    // The second input is 8-bit: the chain is deep because of the first one only.
    let mut rgba = vec![200u8; 4 * 4 * 4];
    rgba.iter_mut().skip(3).step_by(4).for_each(|a| *a = 255);
    let inputs = [
        as_frame(&a, a_strides, PixelFormat::P010, 4, 4, color),
        Frame::from(gpufx_core::Image { data: &rgba, width: 4, height: 4, stride: 16 }),
    ];
    let mut out = vec![0u8; 4 * 4 * 4];
    let mut counts = Vec::new();
    for _ in 0..3 {
        chain.process_frames(&inputs, rgba_target(&mut out), &FrameInfo::new(0.0, 0)).unwrap();
        counts.push(chain.allocations());
        chain.convert(&inputs[0], rgba_target(&mut out)).unwrap();
        counts.push(chain.allocations());
    }
    // Slots and pool once, then the bind groups of the bypass once.
    assert_eq!(counts, [2, 3, 3, 3, 3, 3], "{counts:?}");
}

fn rgba_target(out: &mut [u8]) -> FrameMut<'_> {
    FrameMut {
        format: PixelFormat::Rgba,
        width: 4,
        height: 4,
        planes: [out, &mut [], &mut [], &mut []],
        strides: [16, 0, 0, 0],
        color: ColorInfo::default(),
    }
}
