//! `expr` parameters: compiled into WGSL and GLSL shaders, rebuilt when changed through
//! a chain (the path FFmpeg takes). Skipped when no GPU device can be created.

use std::sync::Arc;

use gpufx_core::{Backend, Effect, EffectChain, FrameInfo, GpuContext, Image, ImageMut, Package};

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

/// A package whose red channel is `level(x)`, x being the horizontal position 0..1.
fn open(ctx: &Arc<GpuContext>, glsl: bool) -> Effect {
    let dir = std::env::temp_dir().join(format!("gpufx-expr-{glsl}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let shader = if glsl { "main.glsl" } else { "main.wgsl" };
    let manifest = format!(
        r#"{{"api":2,"id":"t.expr","name":"Expr","params":[{{"name":"gain","type":"float","default":1}},
            {{"name":"level","type":"expr","vars":["x","gain"],"default":"x * gain"}}],"passes":[{{"shader":"{shader}"}}]}}"#
    );
    std::fs::write(dir.join("manifest.json"), manifest).unwrap();
    let body = if glsl {
        "layout(local_size_x = 8, local_size_y = 8) in;
void main() {
    uvec3 id = gl_GlobalInvocationID;
    if (!gpufx_in_bounds(id)) { return; }
    gpufx_write(id, vec4(gpufx_expr_level(gpufx_uv(id).x, params.gain), 0.0, 0.0, 1.0));
}"
    } else {
        "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    gpufx_write(id, vec4f(gpufx_expr_level(gpufx_uv(id).x, params.gain), 0.0, 0.0, 1.0));
}"
    };
    std::fs::write(dir.join(shader), body).unwrap();
    let fx = Effect::new(ctx.clone(), Package::open(&dir).unwrap()).unwrap();
    std::fs::remove_dir_all(&dir).ok();
    fx
}

const W: u32 = 16;
const H: u32 = 8;

fn red(chain: &mut EffectChain) -> Vec<u8> {
    let src = vec![0u8; (W * H * 4) as usize];
    let mut out = vec![0u8; src.len()];
    let input = Image { data: &src, width: W, height: H, stride: W * 4 };
    chain.process(&[input], ImageMut { data: &mut out, width: W, height: H, stride: W * 4 }, &FrameInfo::new(0.0, 0)).unwrap();
    out[..(W * 4) as usize].chunks(4).map(|p| p[0]).collect()
}

#[test]
fn expressions_are_compiled_into_wgsl_and_glsl() {
    let Some(ctx) = gpu() else { return };
    for glsl in [false, true] {
        let mut chain = EffectChain::new(vec![("e".into(), open(&ctx, glsl))]).unwrap();
        let ramp = red(&mut chain);
        assert!(ramp.windows(2).all(|w| w[0] < w[1]), "glsl {glsl}: default x * gain is a ramp: {ramp:?}");
        // Changed after the first frame: the bound effect gets new pipelines.
        chain.set_param_str("level", "1 - x").unwrap();
        let down = red(&mut chain);
        assert!(down.windows(2).all(|w| w[0] > w[1]), "glsl {glsl}: 1 - x: {down:?}");
        // Plain parameters still reach the expression as variables.
        chain.set_param_str("level", "gain * 0.5").unwrap();
        chain.set_param_str("gain", "0").unwrap();
        assert!(red(&mut chain).iter().all(|&r| r == 0), "glsl {glsl}: gain 0");
        chain.set_param_str("gain", "1").unwrap();
        assert!(red(&mut chain).iter().all(|&r| r == 128), "glsl {glsl}: gain 1");
        // Numbers cannot set an expression; a bad text keeps the last good one.
        assert!(chain.set_param("level", &[0.5]).is_err());
        assert!(chain.set_param_str("level", "x +").is_err());
        assert!(red(&mut chain).iter().all(|&r| r == 128), "glsl {glsl}: last good expression");
        // A long flat chain compiles; NaN comes out as 0.
        chain.set_param_str("level", &vec!["x"; 250].join("+")).unwrap();
        assert!(red(&mut chain).iter().skip(1).all(|&r| r == 255), "glsl {glsl}: long chain");
        chain.set_param_str("level", "sqrt(x - 2)").unwrap();
        assert!(red(&mut chain).iter().all(|&r| r == 0), "glsl {glsl}: NaN is 0");
        chain.set_param_str("level", "x * gain").unwrap();
        assert_eq!(red(&mut chain), ramp, "glsl {glsl}: back to the default");
    }
}
