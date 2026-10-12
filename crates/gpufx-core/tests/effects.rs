//! Runs the example packages on whatever GPU is available (lavapipe/llvmpipe work).
//! Tests that need a device are skipped when none can be created.

use std::path::PathBuf;

use gpufx_core::{Backend, Effect, EffectChain, Error, FrameInfo, GpuContext, Image, ImageMut, Package, StreamInfo};

fn examples() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects")
}

fn gpu() -> Option<std::sync::Arc<GpuContext>> {
    match GpuContext::new(Backend::Auto) {
        Ok(ctx) => {
            // CI logs show which adapter ran the tests (lavapipe, WARP, Metal).
            eprintln!("adapter: {}", ctx.description());
            Some(ctx)
        }
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    }
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
    for entry in std::fs::read_dir(examples()).unwrap() {
        let dir = entry.unwrap().path();
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
    let (w, h) = (160, 90);
    let src = gradient(w, h);
    let inputs = [Image { data: &src, width: w, height: h, stride: w * 4 }];
    for name in ["falling-maple", "falling-ginkgo"] {
        let run = |fx: &mut Effect, t: f64, frame: u64| {
            let mut out = vec![0u8; (w * h * 4) as usize];
            fx.process(&inputs, target(&mut out, w, h, w * 4), &FrameInfo::new(t, frame)).unwrap();
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

#[test]
fn falling_leaves_packages_share_one_shader() {
    let read = |name: &str| std::fs::read(examples().join(name).join("shaders/leaves.wgsl")).unwrap();
    assert!(read("falling-maple") == read("falling-ginkgo"), "keep the two copies of leaves.wgsl identical");
}

fn open(ctx: &std::sync::Arc<GpuContext>, name: &str) -> (String, Effect) {
    (name.to_string(), Effect::new(ctx.clone(), Package::open(examples().join(name)).unwrap()).unwrap())
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
    assert_eq!(out, want);

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
    let yuv_only = TempPackage::new(
        "yuv-only",
        r#"{"id":"t.yuv","name":"YUV only","inputs":[{"name":"src","formats":["yuv420p"],"width":{"max":100}}],"passes":[{"shader":"shaders/main.wgsl"}]}"#,
        "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) { if (gpufx_in_bounds(id)) { gpufx_write(id, textureLoad(src, vec2i(id.xy), 0)); } }",
    );
    let yuv = || ("yuv".to_string(), Effect::new(ctx.clone(), Package::open(&yuv_only.0).unwrap()).unwrap());
    let err = EffectChain::new(vec![open(&ctx, "invert"), yuv()]).err().unwrap().to_string();
    assert!(err.contains("`invert` outputs rgba but `yuv` accepts yuv420p"), "{err}");
    // A YUV-only first effect is fine: its input is the chain input. Later effects check
    // their rules against the size of the first input.
    let chain = EffectChain::new(vec![yuv(), open(&ctx, "invert")]).unwrap();
    let stream = |w| [StreamInfo { format: Some("yuv420p"), width: w, height: 8 }];
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
    assert_eq!(pixel(-0.75, 2.0), [127, 64, 128]);
    // Just below an integer the fraction rounds to 1.0 in f32: it carries over.
    assert_eq!(pixel(4.0 - 1e-9, 1.0), [132, 0, 64]);
    // A day into the clip the fraction is still exact.
    let day = pixel(86400.5, 1.0);
    assert_eq!(day[1], 128);
    // Unknown aspect ratios count as square pixels.
    assert_eq!(pixel(0.0, 0.0)[2], 64);
}
