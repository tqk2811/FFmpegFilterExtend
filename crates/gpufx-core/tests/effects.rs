//! Runs the example packages on whatever GPU is available (lavapipe/llvmpipe work).
//! Tests that need a device are skipped when none can be created.

mod common;

use std::path::PathBuf;

use gpufx_core::{Effect, EffectChain, Error, FrameInfo, GpuContext, Image, ImageMut, Package, StreamInfo};

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

/// One device for every test, as in FFmpeg where all gpufx filters share one. Each test
/// making its own D3D12 device on WARP, from parallel threads, is the suspect for the
/// access violations of the test process on the Windows runner.
fn gpu() -> Option<std::sync::Arc<GpuContext>> {
    static CTX: std::sync::OnceLock<Option<std::sync::Arc<GpuContext>>> = std::sync::OnceLock::new();
    CTX.get_or_init(|| match GpuContext::new(common::backend()) {
        Ok(ctx) => {
            // CI logs show which adapter ran the tests (lavapipe, WARP, Metal).
            eprintln!("adapter: {}", ctx.description());
            Some(ctx)
        }
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    })
    .clone()
}

/// `out` as a w x h output with the given row stride.
fn target(out: &mut [u8], w: u32, h: u32, stride: u32) -> ImageMut<'_> {
    ImageMut { data: out, width: w, height: h, stride }
}

fn gradient(w: u32, h: u32) -> Vec<u8> {
    (0..w * h).flat_map(|i| [(i % w * 255 / w) as u8, (i / w * 255 / h) as u8, 128, 255]).collect()
}

#[test]
fn every_example_compiles_and_runs() {
    let Some(ctx) = gpu() else { return };
    let (w, h) = (67, 41); // not a multiple of the workgroup size on purpose
    let src = gradient(w, h);
    for dir in example_dirs() {
        let mut fx = Effect::new(ctx.clone(), Package::open(&dir).unwrap()).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
        let inputs = vec![Image { data: &src, width: w, height: h, stride: w * 4 }; fx.input_count()];
        let mut out = vec![0u8; (w * h * 4) as usize];
        fx.process(&inputs, target(&mut out, w, h, w * 4), &FrameInfo::new(0.5, 3)).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
        assert!(out.chunks(4).any(|p| p != [0, 0, 0, 0]), "{} produced an empty frame", dir.display());
    }
}

#[test]
fn transitions_start_on_the_first_clip_and_end_on_the_second() {
    let Some(ctx) = gpu() else { return };
    let (w, h) = (67, 41);
    let first = gradient(w, h);
    let second: Vec<u8> = first.chunks(4).flat_map(|p| [255 - p[0], p[2], 255 - p[1], 255]).collect();
    let inputs = [Image { data: &first, width: w, height: h, stride: w * 4 }, Image { data: &second, width: w, height: h, stride: w * 4 }];
    let mut checked = 0;
    for dir in example_dirs() {
        let mut fx = Effect::new(ctx.clone(), Package::open(&dir).unwrap()).unwrap();
        // Transitions: two inputs and a `progress` parameter. photo-collection ends with
        // the second clip lying on the first, so it only starts on the first.
        if fx.input_count() != 2 || fx.params_mut().set_str("progress", "0").is_err() {
            continue;
        }
        let stacks = dir.ends_with("photo-collection");
        for (progress, want) in [("0", &first), ("1", &second)] {
            if stacks && progress == "1" {
                // The photo lies tilted in the middle: the corners still show the first clip.
                fx.params_mut().set_str("progress", "1").unwrap();
                let mut out = vec![0u8; (w * h * 4) as usize];
                fx.process(&inputs, target(&mut out, w, h, w * 4), &FrameInfo::new(0.0, 0)).unwrap();
                assert_eq!(out[..4], first[..4], "photo-collection corner");
                let centre = ((h / 2 * w + w / 2) * 4) as usize;
                assert_ne!(out[centre..centre + 4], first[centre..centre + 4], "photo-collection centre");
                continue;
            }
            fx.params_mut().set_str("progress", progress).unwrap();
            let mut out = vec![0u8; (w * h * 4) as usize];
            fx.process(&inputs, target(&mut out, w, h, w * 4), &FrameInfo::new(0.0, 0)).unwrap();
            let bad = out.chunks(4).zip(want.chunks(4)).position(|(a, b)| a != b);
            assert!(
                bad.is_none(),
                "{} at progress {progress} is not the {} clip: pixel ({}, {}) is {:?}, want {:?}",
                dir.display(),
                if progress == "0" { "first" } else { "second" },
                bad.unwrap_or(0) as u32 % w,
                bad.unwrap_or(0) as u32 / w,
                bad.map(|i| &out[i * 4..i * 4 + 4]),
                bad.map(|i| &want[i * 4..i * 4 + 4]),
            );
        }
        checked += 1;
    }
    assert!(checked >= 17, "only {checked} transitions found");
}

/// The modes that the endpoint test above does not reach (it runs the defaults only):
/// each still starts on the first clip and ends on the second, and its midpoint looks
/// like that mode.
#[test]
fn transition_modes_have_clean_endpoints_and_their_own_midpoint() {
    let Some(ctx) = gpu() else { return };
    let (w, h) = (67, 41);
    let first = gradient(w, h);
    let second: Vec<u8> = first.chunks(4).flat_map(|p| [255 - p[0], p[2], 255 - p[1], 255]).collect();
    let inputs = [Image { data: &first, width: w, height: h, stride: w * 4 }, Image { data: &second, width: w, height: h, stride: w * 4 }];
    let px = |img: &[u8], x: u32, y: u32| img[((y * w + x) * 4) as usize..][..4].to_vec();
    type Check = fn(&dyn Fn(u32, u32) -> Vec<u8>, &dyn Fn(&[u8], u32, u32) -> Vec<u8>, &[u8], &[u8], u32, u32);
    type Case = (&'static str, &'static [(&'static str, &'static str)], &'static str, Check);
    let cases: Vec<Case> = vec![
        // Cover: the left half still shows the first clip, the right half the second.
        ("slide-transition", &[("mode", "1")], "0.5", |out, px, a, b, w, h| {
            assert_eq!(out(2, h / 2), px(a, 2, h / 2));
            assert_ne!(out(w - 3, h / 2), px(a, w - 3, h / 2));
            let _ = b;
        }),
        // Uncover: the right half already shows the still second clip.
        ("slide-transition", &[("mode", "2")], "0.5", |out, px, _a, b, w, h| {
            assert_eq!(out(w - 3, h / 2), px(b, w - 3, h / 2));
        }),
        // Box in: halfway the whole frame is the background color.
        ("slide-transition", &[("mode", "3"), ("color", "#ff0000")], "0.5", |out, _px, _a, _b, w, h| {
            for (x, y) in [(0, 0), (w / 2, h / 2), (w - 1, h - 1)] {
                assert_eq!(out(x, y), [255, 0, 0, 255], "pixel ({x}, {y})");
            }
        }),
        ("slide-transition", &[("mode", "3"), ("direction", "3")], "0.5", |out, _px, _a, _b, w, h| {
            assert_eq!(out(w / 2, h / 2), [0, 0, 0, 255]);
        }),
        // One stripe opening from its center: the middle row is open, the edges are not.
        ("blinds", &[("origin", "1"), ("count", "1"), ("softness", "0")], "0.5", |out, px, a, b, w, h| {
            assert_eq!(out(w / 2, h / 2), px(b, w / 2, h / 2));
            assert_eq!(out(w / 2, 0), px(a, w / 2, 0));
            assert_eq!(out(w / 2, h - 1), px(a, w / 2, h - 1));
        }),
        // Two bars, one after the other: the top one has landed, the bottom one not started.
        ("sliding-bars", &[("count", "2")], "0.5", |out, px, a, b, w, h| {
            assert_eq!(out(w / 2, 2), px(b, w / 2, 2));
            assert_eq!(out(w / 2, h - 3), px(a, w / 2, h - 3));
        }),
        // The clips shrink to nothing halfway: only the background is left.
        ("spin-transition", &[], "0.5", |out, _px, _a, _b, w, h| {
            for (x, y) in [(0, 0), (w / 2, h / 2), (w - 1, h - 1)] {
                assert_eq!(out(x, y), [0, 0, 0, 255], "pixel ({x}, {y})");
            }
        }),
        // Off-centre progress, so a flipped direction lands on the wrong side.
        // Cover from the left: a strip of the second clip on the left, the first elsewhere.
        ("slide-transition", &[("mode", "1"), ("direction", "1")], "0.25", |out, px, a, _b, w, h| {
            assert_ne!(out(1, h / 2), px(a, 1, h / 2));
            assert_eq!(out(w - 3, h / 2), px(a, w - 3, h / 2));
        }),
        // Uncover to the right: the still second clip shows on the left.
        ("slide-transition", &[("mode", "2"), ("direction", "1")], "0.25", |out, px, _a, b, w, h| {
            assert_eq!(out(1, h / 2), px(b, 1, h / 2));
            assert_ne!(out(w - 3, h / 2), px(b, w - 3, h / 2));
        }),
        // Push through color to the right: the gap opens on the left, then closes on the right.
        ("slide-transition", &[("mode", "3"), ("direction", "1"), ("color", "#ff0000")], "0.25", |out, _px, _a, _b, w, h| {
            assert_eq!(out(1, h / 2), [255, 0, 0, 255]);
            assert_ne!(out(w - 2, h / 2), [255, 0, 0, 255]);
        }),
        ("slide-transition", &[("mode", "3"), ("direction", "1"), ("color", "#ff0000")], "0.75", |out, _px, _a, _b, w, h| {
            assert_ne!(out(1, h / 2), [255, 0, 0, 255]);
            assert_eq!(out(w - 2, h / 2), [255, 0, 0, 255]);
        }),
        // Vertical bars all together, coming up from the bottom: a quarter in, the bottom
        // rows show the top of the second clip, the top rows still the first.
        ("sliding-bars", &[("direction", "1"), ("vertical", "1"), ("stagger", "0")], "0.25", |out, px, a, b, w, h| {
            assert_eq!(out(w / 2, 2), px(a, w / 2, 2));
            // Row h - 2 samples the second clip at texel 39.5 - 0.75 * 41 = 8.75, near row 8.
            assert!(near(&out(w / 2, h - 2), &px(b, w / 2, 8)), "{:?} vs {:?}", out(w / 2, h - 2), px(b, w / 2, 8));
        }),
        // A quarter turn without zoom: the centre stays put and the frame is rotated
        // counterclockwise on screen: the pixel right of the centre comes from above it.
        ("spin-transition", &[("zoom", "0"), ("turns", "0.5"), ("blur", "1")], "0.25", |out, px, a, _b, w, h| {
            assert_eq!(out(w / 2, h / 2), px(a, w / 2, h / 2));
            assert!(near(&out(w / 2 + 10, h / 2), &px(a, w / 2, h / 2 - 10)), "{:?}", out(w / 2 + 10, h / 2));
            assert_eq!(out(0, 0), [0, 0, 0, 255]);
        }),
        // turns rounds to whole half turns, so 0.3 spins like 0.5 (and both halves meet).
        ("spin-transition", &[("zoom", "0"), ("turns", "0.3"), ("blur", "1")], "0.25", |out, px, a, _b, w, h| {
            assert!(near(&out(w / 2 + 10, h / 2), &px(a, w / 2, h / 2 - 10)), "{:?}", out(w / 2 + 10, h / 2));
        }),
        // Box in: zoomed out, a centred box of the first clip on the background.
        ("box-in", &[("color", "#ff0000")], "0.25", |out, px, a, _b, w, h| {
            assert_eq!(out(w / 2, h / 2), px(a, w / 2, h / 2));
            assert_eq!(out(0, 0), [255, 0, 0, 255]);
            assert_eq!(out(2, h / 2), [255, 0, 0, 255]);
            assert_eq!(out(w - 3, h / 2), [255, 0, 0, 255]);
        }),
        // Halfway out: the first box leaves to the right (the side the second comes from).
        ("box-in", &[("color", "#ff0000")], "0.375", |out, _px, _a, _b, w, h| {
            assert_eq!(out(3, h / 2), [255, 0, 0, 255]);
            assert_eq!(out(w / 2, h / 2), [255, 0, 0, 255]);
            assert_ne!(out(w - 3, h / 2), [255, 0, 0, 255]);
        }),
        ("box-in", &[("color", "#ff0000")], "0.5", |out, _px, _a, _b, w, h| {
            for (x, y) in [(0, 0), (w / 2, h / 2), (w - 1, h - 1)] {
                assert_eq!(out(x, y), [255, 0, 0, 255], "pixel ({x}, {y})");
            }
        }),
        // Halfway in: the second box comes from the right; its left part shows there.
        ("box-in", &[("color", "#ff0000")], "0.625", |out, px, _a, b, w, h| {
            assert_eq!(out(3, h / 2), [255, 0, 0, 255]);
            assert!(near(&out(w - 3, h / 2), &px(b, 28, h / 2)), "{:?}", out(w - 3, h / 2));
        }),
        // Vertical, moving up: the first box leaves downwards.
        ("box-in", &[("color", "#ff0000"), ("direction", "2")], "0.375", |out, _px, _a, _b, w, h| {
            assert_eq!(out(w / 2, 2), [255, 0, 0, 255]);
            assert_ne!(out(w / 2, h - 3), [255, 0, 0, 255]);
        }),
        // Zooming in: a bigger centred box of the second clip.
        ("box-in", &[("color", "#ff0000")], "0.875", |out, px, _a, b, w, h| {
            assert_eq!(out(w / 2, h / 2), px(b, w / 2, h / 2));
            assert_eq!(out(0, 0), [255, 0, 0, 255]);
        }),
    ];
    for (name, settings, at, check) in cases {
        let (_, mut fx) = open(&ctx, name);
        for (k, v) in settings {
            fx.params_mut().set_str(k, v).unwrap();
        }
        let mut run = |progress: &str| {
            fx.params_mut().set_str("progress", progress).unwrap();
            let mut out = vec![0u8; first.len()];
            fx.process(&inputs, target(&mut out, w, h, w * 4), &FrameInfo::new(0.0, 0)).unwrap();
            out
        };
        assert!(run("0") == first, "{name} {settings:?} at progress 0 is not the first clip");
        assert!(run("1") == second, "{name} {settings:?} at progress 1 is not the second clip");
        let mid = run(at);
        let out = |x: u32, y: u32| px(&mid, x, y);
        check(&out, &px, &first, &second, w, h);
    }
}

#[test]
fn zero_strength_vignette_is_identity() {
    let Some(ctx) = gpu() else { return };
    let mut fx = Effect::new(ctx, Package::open(example("vignette")).unwrap()).unwrap();
    fx.params_mut().set_str("strength", "0").unwrap();
    let (w, h) = (32, 16);
    let src = gradient(w, h);
    // Padded output rows must be honoured.
    let stride = w * 4 + 12;
    let mut out = vec![0u8; (stride * h) as usize];
    fx.process(&[Image { data: &src, width: w, height: h, stride: w * 4 }], target(&mut out, w, h, stride), &FrameInfo::new(0.0, 0))
        .unwrap();
    for y in 0..h as usize {
        assert_eq!(&out[y * stride as usize..][..(w * 4) as usize], &src[y * (w * 4) as usize..][..(w * 4) as usize]);
    }
}

#[test]
fn shader_errors_point_at_the_author_file() {
    let Some(ctx) = gpu() else { return };
    let dir = std::env::temp_dir().join(format!("gpufx-bad-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("shaders")).unwrap();
    std::fs::write(
        dir.join("manifest.json"),
        r#"{"id":"t.bad","name":"Bad","inputs":[{"name":"src"}],"passes":[{"shader":"shaders/bad.wgsl"}]}"#,
    )
    .unwrap();
    std::fs::write(dir.join("shaders/bad.wgsl"), "@compute @workgroup_size(8,8) fn main() { let x = undefined_thing; }").unwrap();
    let err = Effect::new(ctx, Package::open(&dir).unwrap()).err().expect("must fail");
    std::fs::remove_dir_all(&dir).ok();
    match err {
        Error::Shader(msg) => assert!(msg.contains("shaders/bad.wgsl") && msg.contains("undefined_thing"), "{msg}"),
        other => panic!("unexpected error {other}"),
    }
}

#[test]
fn falling_leaves_depend_only_on_time() {
    let Some(ctx) = gpu() else { return };
    if common::is_warp(&ctx) {
        // ~35 frames per effect take over 8 minutes on WARP; lavapipe and real GPUs cover it.
        eprintln!("skipping: the falling leaves take minutes on WARP");
        return;
    }
    let (w, h) = (160, 90);
    let src = gradient(w, h);
    let inputs = [Image { data: &src, width: w, height: h, stride: w * 4 }];
    for name in ["falling-maple", "falling-ginkgo"] {
        let run = |fx: &mut Effect, t: f64, frame: u64| {
            let mut out = vec![0u8; (w * h * 4) as usize];
            fx.process(&inputs, target(&mut out, w, h, w * 4), &FrameInfo::new(t, frame)).unwrap();
            out
        };
        let open = || Effect::new(ctx.clone(), Package::open(example(name)).unwrap()).unwrap();
        let mut played = open();
        let mut frames = Vec::new();
        for k in 0..=12u64 {
            frames.push(run(&mut played, k as f64 * 0.25, k));
        }
        // A fresh effect seeking straight to t = 3 draws what playing up to it drew,
        // whatever the frame counter says.
        let mut seeked = open();
        assert_eq!(run(&mut seeked, 3.0, 0), frames[12], "{name}: seek");
        // Playing backwards draws the same frames.
        let mut reverse = open();
        for k in (0..=12u64).rev() {
            assert_eq!(run(&mut reverse, k as f64 * 0.25, 12 - k), frames[k as usize], "{name}: reverse at frame {k}");
        }
        // Steady density: the share of covered pixels stays in a band, at the start and
        // deep into the clip (catches leaves falling all at once, or never respawning).
        for t in [0.0, 7.3, 61.7, 3600.0] {
            let frame = run(&mut reverse, t, 0);
            let covered = frame.chunks(4).zip(src.chunks(4)).filter(|(a, b)| a != b).count() as f64 / (w * h) as f64;
            assert!((0.02..=0.30).contains(&covered), "{name}: {:.1}% covered at t = {t}", covered * 100.0);
        }
        reverse.params_mut().set_str("seed", "2").unwrap();
        assert_ne!(run(&mut reverse, 3.0, 0), frames[12], "{name}: another seed, other leaves");
        reverse.params_mut().set_str("opacity", "0").unwrap();
        assert_eq!(run(&mut reverse, 3.0, 0), src, "{name}: opacity 0 leaves the frame untouched");
        // Mode 4: paths from expressions, compiled into the shader when they change.
        let mut custom = open();
        custom.params_mut().set_str("mode", "4").unwrap();
        let first = run(&mut custom, 2.0, 0);
        assert_ne!(first, src, "{name}: custom paths draw leaves");
        assert_eq!(run(&mut open_mode4(&open), 2.0, 0), first, "{name}: custom paths are stateless");
        custom.params_mut().set_str("path_x", "x0 + 0.3*sin(u)").unwrap();
        let moved = run(&mut custom, 2.0, 0);
        assert_ne!(moved, first, "{name}: a new path_x moves the leaves");
        // Everything above the frame: nothing drawn. NaN paths are dropped.
        custom.params_mut().set_str("path_y", "-5").unwrap();
        assert_eq!(run(&mut custom, 2.0, 0), src, "{name}: leaves off the frame");
        custom.params_mut().set_str("path_y", "0.5").unwrap();
        let middle = run(&mut custom, 2.0, 0);
        custom.params_mut().set_str("path_y", "0.5 + log(-1)").unwrap();
        assert_ne!(run(&mut custom, 2.0, 0), middle, "{name}: NaN reaches the shader as 0");
        custom.params_mut().set_str("path_y", "0").unwrap();
        let top = run(&mut custom, 2.0, 0);
        custom.params_mut().set_str("path_y", "log(-1)").unwrap();
        assert_eq!(run(&mut custom, 2.0, 0), top, "{name}: NaN positions become 0");
        assert!(custom.params_mut().set_str("path_y", "textureLoad(src)").is_err(), "{name}: only math");
        // Back to the default texts: the shared pipelines again, same picture.
        custom.params_mut().set_str("path_y", "-0.1 + 1.2*p").unwrap();
        custom.params_mut().set_str("path_x", "x0 + 0.05*sin(tau*(0.5*u + r1))").unwrap();
        assert_eq!(run(&mut custom, 2.0, 0), first, "{name}: default paths again");
        assert_ne!(frames[0], frames[1], "{name}: leaves must move");
        assert!(frames.iter().all(|f| f != &src), "{name}: leaves must be visible");
        // Eleven days in, f32 seconds would step by 0.0625 s and repeat frames at 30 fps:
        // leaves must still move every frame.
        let late = 1_000_000.0;
        assert_ne!(run(&mut seeked, late, 0), run(&mut seeked, late + 1.0 / 30.0, 1), "{name}: precise time");
        assert_ne!(run(&mut seeked, late, 0), run(&mut seeked, late + 0.005, 1), "{name}: time between ticks");
        // Deep into the clip the sky is still full: leaves respawn.
        assert_ne!(run(&mut seeked, 3600.0, 0), src, "{name}: respawn");
        let tumble = run(&mut seeked, 1.0, 0);
        for mode in ["1", "2", "3"] {
            seeked.params_mut().set_str("mode", mode).unwrap();
            let frame = run(&mut seeked, 1.0, 0);
            assert!(frame != src && frame != tumble, "{name}: mode {mode} must draw its own motion");
        }
        seeked.params_mut().set_str("mode", "0").unwrap();
        // Before t = 0 (offset, or slightly negative pts) the sky is already full.
        assert_ne!(run(&mut seeked, -50.0, 0), src, "{name}: negative time");
        seeked.params_mut().set_str("count", "0").unwrap();
        assert_eq!(run(&mut seeked, 1.0, 0), src, "{name}: no leaves leaves the frame untouched");
        // Transparent input keeps its colour where no leaf is drawn.
        let clear: Vec<u8> = src.chunks(4).flat_map(|p| [p[0], p[1], p[2], 0]).collect();
        let mut out = vec![0u8; clear.len()];
        seeked
            .process(&[Image { data: &clear, width: w, height: h, stride: w * 4 }], target(&mut out, w, h, w * 4), &FrameInfo::new(1.0, 0))
            .unwrap();
        assert_eq!(out, clear, "{name}: transparent pixels pass through");
    }
}

fn open_mode4(open: &dyn Fn() -> Effect) -> Effect {
    let mut fx = open();
    fx.params_mut().set_str("mode", "4").unwrap();
    fx
}

#[test]
fn falling_leaves_packages_share_one_shader() {
    let read = |name: &str| std::fs::read(example(name).join("shaders/leaves.wgsl")).unwrap();
    assert!(read("falling-maple") == read("falling-ginkgo"), "keep the two copies of leaves.wgsl identical");
}

fn open(ctx: &std::sync::Arc<GpuContext>, name: &str) -> (String, Effect) {
    (name.to_string(), Effect::new(ctx.clone(), Package::open(example(name)).unwrap()).unwrap())
}

/// A package in a temporary directory with one pass `shader`; removed on drop.
struct TempPackage(PathBuf);

impl TempPackage {
    fn new(tag: &str, manifest: &str, shader: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("gpufx-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("shaders")).unwrap();
        std::fs::write(dir.join("manifest.json"), manifest).unwrap();
        std::fs::write(dir.join("shaders/main.wgsl"), shader).unwrap();
        TempPackage(dir)
    }
}

impl Drop for TempPackage {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).ok();
    }
}

#[test]
fn a_chain_runs_like_its_effects_one_after_the_other() {
    let Some(ctx) = gpu() else { return };
    let (w, h) = (67, 41);
    let src = gradient(w, h);
    let input = [Image { data: &src, width: w, height: h, stride: w * 4 }];
    let info = FrameInfo::new(0.5, 3);
    let run = |fx: &mut Effect, data: &[u8]| {
        let mut out = vec![0u8; data.len()];
        fx.process(&[Image { data, width: w, height: h, stride: w * 4 }], target(&mut out, w, h, w * 4), &info).unwrap();
        out
    };
    let (_, mut gray) = open(&ctx, "grayscale");
    let (_, mut vignette) = open(&ctx, "vignette");
    let want = run(&mut vignette, &run(&mut gray, &src));

    let mut chain = EffectChain::new(vec![open(&ctx, "grayscale"), open(&ctx, "vignette")]).unwrap();
    let mut out = vec![0u8; src.len()];
    chain.process(&input, target(&mut out, w, h, w * 4), &info).unwrap();
    // The chain keeps the gray frame in half float instead of rounding it to 8 bits.
    let diff = out.iter().zip(&want).map(|(a, b)| a.abs_diff(*b)).max().unwrap();
    assert!(diff <= 1, "chain differs from two effects by {diff}");

    // Inverting twice restores the frame.
    let mut twice = EffectChain::new(vec![open(&ctx, "invert"), open(&ctx, "invert")]).unwrap();
    twice.process(&input, target(&mut out, w, h, w * 4), &info).unwrap();
    assert_eq!(out, src);
    // The second effect is 1.amount: 0 leaves one inversion.
    twice.set_param_str("1.amount", "0").unwrap();
    twice.process(&input, target(&mut out, w, h, w * 4), &info).unwrap();
    assert_eq!(out, run(&mut open(&ctx, "invert").1, &src));

    // A different frame size rebuilds the textures of every effect.
    let small = gradient(9, 5);
    let mut out_small = vec![0u8; small.len()];
    twice.process(&[Image { data: &small, width: 9, height: 5, stride: 36 }], target(&mut out_small, 9, 5, 36), &info).unwrap();
    assert_ne!(out_small, small);
    // The output must have the size of the first input.
    let err = twice.process(&input, target(&mut out_small, 9, 5, 36), &info).unwrap_err();
    assert!(err.to_string().contains("output is 9x5"), "{err}");
}

#[test]
fn chain_parameters_are_named_after_their_package() {
    let Some(ctx) = gpu() else { return };
    let single = EffectChain::new(vec![open(&ctx, "vignette")]).unwrap();
    assert!(single.param_names().iter().any(|n| n == "strength"));

    let mut chain = EffectChain::new(vec![open(&ctx, "invert"), open(&ctx, "vignette"), open(&ctx, "invert")]).unwrap();
    let names = chain.param_names();
    assert!(names.iter().any(|n| n == "vignette.strength"), "{names:?}");
    // Two packages with one label: only the index tells them apart.
    assert!(names.iter().any(|n| n == "0.amount") && names.iter().any(|n| n == "2.amount"), "{names:?}");
    assert_eq!(chain.find_param("strength").unwrap(), chain.find_param("vignette.strength").unwrap());
    assert_eq!(chain.find_param("1.strength").unwrap(), chain.find_param("vignette.strength").unwrap());
    let err = |name: &str| chain.find_param(name).unwrap_err().to_string();
    assert!(err("amount").contains("0.amount, 2.amount"), "{}", err("amount"));
    assert!(err("invert.amount").contains("use the index"), "{}", err("invert.amount"));
    assert!(err("blur.amount").contains("no effect `blur`"), "{}", err("blur.amount"));
    assert!(err("5.amount").contains("no effect `5`"), "{}", err("5.amount"));
    assert!(err("vignette.amount").contains("has no parameter `amount`"), "{}", err("vignette.amount"));
    chain.set_param_str("2.amount", "0.5").unwrap();
    chain.set_param("strength", &[0.0]).unwrap();
    assert_eq!(chain.effects()[2].params().get("amount").unwrap().0[0], 0.5);
    assert_eq!(chain.effects()[0].params().get("amount").unwrap().0[0], 1.0);
}

#[test]
fn chain_rules_follow_two_filters_in_a_row() {
    let Some(ctx) = gpu() else { return };
    // Only the first effect may take several inputs.
    let err = EffectChain::new(vec![open(&ctx, "invert"), open(&ctx, "crossfade")]).err().unwrap().to_string();
    assert!(err.contains("takes 2 inputs"), "{err}");
    let mut transition = EffectChain::new(vec![open(&ctx, "crossfade"), open(&ctx, "invert")]).unwrap();
    let src = gradient(8, 8);
    let img = Image { data: &src, width: 8, height: 8, stride: 32 };
    let mut out = vec![0u8; src.len()];
    transition.process(&[img, img], target(&mut out, 8, 8, 32), &FrameInfo::new(0.0, 0)).unwrap();

    // The format the first effect outputs must be one the next accepts.
    let gray_only = TempPackage::new(
        "gray-only",
        r#"{"id":"t.gray","name":"Gray only","inputs":[{"name":"src","formats":["gray"],"width":{"max":100}}],"passes":[{"shader":"shaders/main.wgsl"}]}"#,
        "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) { if (gpufx_in_bounds(id)) { gpufx_write(id, textureLoad(src, vec2i(id.xy), 0)); } }",
    );
    let gray = || ("gray".to_string(), Effect::new(ctx.clone(), Package::open(&gray_only.0).unwrap()).unwrap());
    let err = EffectChain::new(vec![open(&ctx, "invert"), gray()]).err().unwrap().to_string();
    assert!(err.contains("`invert` outputs rgba, rgba64le, nv12") && err.contains("but `gray` accepts gray"), "{err}");
    // An effect without output rules may output YUV, as two filters would negotiate.
    let yuv_only = TempPackage::new(
        "yuv-only",
        r#"{"id":"t.yuv","name":"YUV only","inputs":[{"name":"src","formats":["yuv420p"]}],"passes":[{"shader":"shaders/main.wgsl"}]}"#,
        "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) { if (gpufx_in_bounds(id)) { gpufx_write(id, textureLoad(src, vec2i(id.xy), 0)); } }",
    );
    EffectChain::new(vec![
        open(&ctx, "invert"),
        ("yuv".to_string(), Effect::new(ctx.clone(), Package::open(&yuv_only.0).unwrap()).unwrap()),
    ])
    .unwrap();
    // A gray-only first effect is fine: its input is the chain input. Later effects check
    // their rules against the size of the first input.
    let chain = EffectChain::new(vec![gray(), open(&ctx, "invert")]).unwrap();
    let stream = |w| [StreamInfo { format: Some("gray"), width: w, height: 8 }];
    chain.check_inputs(&stream(64)).unwrap();
    assert!(chain.check_inputs(&stream(128)).is_err());
    let narrow = TempPackage::new(
        "narrow",
        r#"{"id":"t.narrow","name":"Narrow","inputs":[{"name":"src","width":{"max":100}}],"passes":[{"shader":"shaders/main.wgsl"}]}"#,
        "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) { if (gpufx_in_bounds(id)) { gpufx_write(id, textureLoad(src, vec2i(id.xy), 0)); } }",
    );
    let narrow = ("narrow".to_string(), Effect::new(ctx.clone(), Package::open(&narrow.0).unwrap()).unwrap());
    let mut late = EffectChain::new(vec![open(&ctx, "invert"), narrow]).unwrap();
    let gray = |w| [StreamInfo { format: Some("gray"), width: w, height: 8 }];
    late.check_inputs(&gray(64)).unwrap();
    let err = late.check_inputs(&gray(128)).unwrap_err().to_string();
    assert!(err.contains("above the maximum 100"), "{err}");
    let wide = gradient(128, 8);
    let mut out = vec![0u8; wide.len()];
    let err =
        late.process(&[Image { data: &wide, width: 128, height: 8, stride: 512 }], target(&mut out, 128, 8, 512), &FrameInfo::new(0.0, 0));
    assert!(err.is_err());
}

#[test]
fn globals_hold_precise_time_and_pixel_aspect() {
    let Some(ctx) = gpu() else { return };
    let pkg = TempPackage::new(
        "globals",
        r#"{"id":"t.globals","name":"Globals","passes":[{"shader":"shaders/main.wgsl"}]}"#,
        "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {
             if (!gpufx_in_bounds(id)) { return; }
             gpufx_write(id, vec4f(f32(globals.time_int + 128) / 255.0, globals.time_frac, globals.pixel_aspect / 4.0, 1.0));
         }",
    );
    let mut fx = Effect::new(ctx, Package::open(&pkg.0).unwrap()).unwrap();
    let src = gradient(4, 4);
    let mut pixel = |time: f64, pixel_aspect: f64| {
        let mut out = vec![0u8; src.len()];
        fx.process(
            &[Image { data: &src, width: 4, height: 4, stride: 16 }],
            target(&mut out, 4, 4, 16),
            &FrameInfo { time, frame: 0, pixel_aspect },
        )
        .unwrap();
        [out[0], out[1], out[2]]
    };
    assert_eq!(pixel(3.25, 1.0), [131, 64, 64]);
    // pixel_aspect / 4 stays off .5 * 255: GPUs may round 127.5 either way.
    assert_eq!(pixel(-0.75, 3.0), [127, 64, 191]);
    // Just below an integer the fraction rounds to 1.0 in f32: it carries over.
    assert_eq!(pixel(4.0 - 1e-9, 1.0), [132, 0, 64]);
    // A day into the clip the fraction is still exact.
    let day = pixel(86400.25, 1.0);
    assert_eq!(day[1], 64);
    // Unknown aspect ratios count as square pixels.
    assert_eq!(pixel(0.0, 0.0)[2], 64);
}

#[test]
fn fit_places_any_picture_in_the_frame() {
    let Some(ctx) = gpu() else { return };
    let (w, h) = (64, 36);
    let canvas = vec![0u8; (w * h * 4) as usize];
    let (pw, ph) = (20, 30); // portrait, smaller than the frame
    let photo = gradient(pw, ph);
    let inputs =
        [Image { data: &canvas, width: w, height: h, stride: w * 4 }, Image { data: &photo, width: pw, height: ph, stride: pw * 4 }];
    let (_, mut fx) = open(&ctx, "fit");
    let mut run = |mode: &str| {
        fx.params_mut().set_str("mode", mode).unwrap();
        let mut out = vec![0u8; canvas.len()];
        fx.process(&inputs, target(&mut out, w, h, w * 4), &FrameInfo::new(0.0, 0)).unwrap();
        out
    };
    let px = |out: &[u8], x: u32, y: u32| out[((y * w + x) * 4) as usize..][..4].to_vec();
    // Centered at its own size: black around it, the picture in the middle.
    let center = run("0");
    assert_eq!(px(&center, 0, 0), [0, 0, 0, 255]);
    assert_eq!(px(&center, w / 2, h / 2)[3], 255);
    assert_ne!(px(&center, w / 2, h / 2), [0, 0, 0, 255]);
    // Crop and stretch fill the frame; blur fills the sides with the blurred copy.
    for mode in ["1", "2", "3"] {
        let out = run(mode);
        assert_ne!(px(&out, 0, 0), [0, 0, 0, 255], "mode {mode}");
        assert_ne!(px(&out, w - 1, h - 1), [0, 0, 0, 255], "mode {mode}");
    }
}

#[test]
fn pooled_pass_outputs_do_not_clobber_each_other() {
    // Pass outputs of a chain share a few pooled textures; multi-pass effects in a row
    // must still give what each effect gives alone (8-bit frames: exact).
    let Some(ctx) = gpu() else { return };
    let (w, h) = (67, 41);
    let src = gradient(w, h);
    let info = FrameInfo::new(0.5, 3);
    let run = |fx: &mut Effect, data: &[u8]| {
        let mut out = vec![0u8; data.len()];
        fx.process(&[Image { data, width: w, height: h, stride: w * 4 }], target(&mut out, w, h, w * 4), &info).unwrap();
        out
    };
    let names = ["gaussian-blur", "invert", "gaussian-blur", "sharpen", "gaussian-blur"];
    let mut want = src.clone();
    for name in names {
        want = run(&mut open(&ctx, name).1, &want);
    }
    let mut chain = EffectChain::new(names.iter().map(|n| open(&ctx, n)).collect()).unwrap();
    let mut out = vec![0u8; src.len()];
    chain.process(&[Image { data: &src, width: w, height: h, stride: w * 4 }], target(&mut out, w, h, w * 4), &info).unwrap();
    assert_eq!(out, want);
}

/// Effects are opened on the noop device until they get theirs (as libgpufx does): every
/// example must compile there as it does on a GPU.
#[test]
fn every_example_opens_on_the_noop_device() {
    let ctx = GpuContext::noop().expect("the noop backend is built in");
    let mut opened = 0;
    for path in example_dirs() {
        let package = Package::open(&path).unwrap();
        if let Err(e) = Effect::new(ctx.clone(), package) {
            panic!("{}: {e}", path.display());
        }
        opened += 1;
    }
    assert!(opened > 10, "{opened} examples");
}

#[test]
fn pack_skips_compiled_folder_and_its_own_output() {
    let tmp = std::env::temp_dir().join(format!("gpufx-pack-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    let dir = tmp.join("invert");
    std::fs::create_dir_all(&dir).unwrap();
    fn copy(from: &std::path::Path, to: &std::path::Path) {
        std::fs::create_dir_all(to).unwrap();
        for e in std::fs::read_dir(from).unwrap() {
            let e = e.unwrap();
            if e.file_type().unwrap().is_dir() {
                copy(&e.path(), &to.join(e.file_name()));
            } else {
                std::fs::copy(e.path(), to.join(e.file_name())).unwrap();
            }
        }
    }
    copy(&example("invert"), &dir);
    // Stale blobs in a top-level `Compiled` folder (any case) never ship...
    std::fs::create_dir_all(dir.join("Compiled/dx12")).unwrap();
    std::fs::write(dir.join("Compiled/dx12/stale.dxil"), b"stale").unwrap();
    // ...but a nested `compiled` folder is ordinary content.
    std::fs::create_dir_all(dir.join("assets/compiled")).unwrap();
    std::fs::write(dir.join("assets/compiled/keep.txt"), b"keep").unwrap();
    // An older output inside the directory is not packed into the new one.
    let out = dir.join("out.zip");
    std::fs::write(&out, b"old zip").unwrap();
    Package::pack(&dir, &out, false).unwrap();
    let pkg = Package::open(&out).unwrap();
    assert!(pkg.file("Compiled/dx12/stale.dxil").is_err());
    assert!(pkg.file("compiled/dx12/stale.dxil").is_err());
    assert_eq!(pkg.file("assets/compiled/keep.txt").unwrap(), b"keep");
    assert!(pkg.file("out.zip").is_err());
    let _ = std::fs::remove_dir_all(&tmp);
}

/// Two pixels equal within the rounding of a filtered sample between neighbours.
fn near(a: &[u8], b: &[u8]) -> bool {
    a.iter().zip(b).all(|(x, y)| x.abs_diff(*y) <= 3)
}
