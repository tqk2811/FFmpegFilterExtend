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
