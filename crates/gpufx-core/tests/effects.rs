//! Runs the example packages on whatever GPU is available (lavapipe/llvmpipe work).
//! Tests that need a device are skipped when none can be created.

use std::path::PathBuf;

use gpufx_core::{Backend, Effect, Error, GpuContext, Image, Package};

fn examples() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects")
}

fn gpu() -> Option<std::sync::Arc<GpuContext>> {
    match GpuContext::new(Backend::Auto) {
        Ok(ctx) => Some(ctx),
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    }
}

fn gradient(w: u32, h: u32) -> Vec<u8> {
    (0..w * h).flat_map(|i| [(i % w * 255 / w) as u8, (i / w * 255 / h) as u8, 128, 255]).collect()
}

#[test]
fn every_example_compiles_and_runs() {
    let Some(ctx) = gpu() else { return };
    let (w, h) = (67, 41); // not a multiple of the workgroup size on purpose
    let src = gradient(w, h);
    for entry in std::fs::read_dir(examples()).unwrap() {
        let dir = entry.unwrap().path();
        let mut fx = Effect::new(ctx.clone(), Package::open(&dir).unwrap()).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
        let inputs = vec![Image { data: &src, width: w, height: h, stride: w * 4 }; fx.input_count()];
        let mut out = vec![0u8; (w * h * 4) as usize];
        fx.process(&inputs, &mut out, w * 4, 0.5, 3).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
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
    for entry in std::fs::read_dir(examples()).unwrap() {
        let dir = entry.unwrap().path();
        let mut fx = Effect::new(ctx.clone(), Package::open(&dir).unwrap()).unwrap();
        // Transitions: two inputs and a `progress` parameter.
        if fx.input_count() != 2 || fx.params_mut().set_str("progress", "0").is_err() {
            continue;
        }
        for (progress, want) in [("0", &first), ("1", &second)] {
            fx.params_mut().set_str("progress", progress).unwrap();
            let mut out = vec![0u8; (w * h * 4) as usize];
            fx.process(&inputs, &mut out, w * 4, 0.0, 0).unwrap();
            assert!(
                &out == want,
                "{} at progress {progress} is not the {} clip",
                dir.display(),
                if progress == "0" { "first" } else { "second" }
            );
        }
        checked += 1;
    }
    assert!(checked >= 13, "only {checked} transitions found");
}

#[test]
fn zero_strength_vignette_is_identity() {
    let Some(ctx) = gpu() else { return };
    let mut fx = Effect::new(ctx, Package::open(examples().join("vignette")).unwrap()).unwrap();
    fx.params_mut().set_str("strength", "0").unwrap();
    let (w, h) = (32, 16);
    let src = gradient(w, h);
    // Padded output rows must be honoured.
    let stride = w * 4 + 12;
    let mut out = vec![0u8; (stride * h) as usize];
    fx.process(&[Image { data: &src, width: w, height: h, stride: w * 4 }], &mut out, stride, 0.0, 0).unwrap();
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
    let (w, h) = (160, 90);
    let src = gradient(w, h);
    let inputs = [Image { data: &src, width: w, height: h, stride: w * 4 }];
    for name in ["falling-maple", "falling-ginkgo"] {
        let run = |fx: &mut Effect, t: f64, frame: u64| {
            let mut out = vec![0u8; (w * h * 4) as usize];
            fx.process(&inputs, &mut out, w * 4, t, frame).unwrap();
            out
        };
        let open = || Effect::new(ctx.clone(), Package::open(examples().join(name)).unwrap()).unwrap();
        let mut played = open();
        let mut frames = Vec::new();
        for k in 0..=12u64 {
            frames.push(run(&mut played, k as f64 * 0.25, k));
        }
        // A fresh effect seeking straight to t = 3 draws what playing up to it drew,
        // whatever the frame counter says.
        let mut seeked = open();
        assert_eq!(run(&mut seeked, 3.0, 0), frames[12], "{name}: seek");
        assert_ne!(frames[0], frames[1], "{name}: leaves must move");
        assert!(frames.iter().all(|f| f != &src), "{name}: leaves must be visible");
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
        seeked.process(&[Image { data: &clear, width: w, height: h, stride: w * 4 }], &mut out, w * 4, 1.0, 0).unwrap();
        assert_eq!(out, clear, "{name}: transparent pixels pass through");
    }
}

#[test]
fn falling_leaves_packages_share_one_shader() {
    let read = |name: &str| std::fs::read(examples().join(name).join("shaders/leaves.wgsl")).unwrap();
    assert!(read("falling-maple") == read("falling-ginkgo"), "keep the two copies of leaves.wgsl identical");
}
