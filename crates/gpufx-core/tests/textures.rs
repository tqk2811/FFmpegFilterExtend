//! Package textures (texture arrays, atlas grids, mipmaps, premultiplied alpha), their
//! size limits, and mip chains of effect inputs. GPU tests are skipped without a device.

mod common;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use gpufx_core::{ColorInfo, Effect, EffectChain, Error, Frame, FrameInfo, FrameMut, GpuContext, Image, ImageMut, Package, PixelFormat};

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

/// A package directory under the temp dir, removed when dropped.
struct Dir(PathBuf);

impl Drop for Dir {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).ok();
    }
}

fn png(path: &Path, w: u32, h: u32, pixel: impl Fn(u32, u32) -> [u8; 4]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    image::RgbaImage::from_fn(w, h, |x, y| image::Rgba(pixel(x, y))).save(path).unwrap();
}

/// Writes `manifest` and one shader, `main.wgsl` (or `main.glsl` when `glsl`).
fn package_dir(tag: &str, manifest: &str, shader: &str, glsl: bool) -> Dir {
    let dir = std::env::temp_dir().join(format!("gpufx-tex-{tag}-{}", std::process::id()));
    std::fs::remove_dir_all(&dir).ok();
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("manifest.json"), manifest).unwrap();
    std::fs::write(dir.join(if glsl { "main.glsl" } else { "main.wgsl" }), shader).unwrap();
    Dir(dir)
}

fn manifest(extra: &str) -> String {
    format!(r#"{{"api":2,"id":"t.tex","name":"Tex","passes":[{{"shader":"main.wgsl"}}]{extra}}}"#)
}

const RED: [u8; 4] = [255, 0, 0, 255];
const BLUE: [u8; 4] = [0, 0, 255, 255];

/// Runs `fx` on a `w` x `h` frame of `src` (default grey) and returns the RGBA result.
fn run(fx: &mut Effect, w: u32, h: u32, src: Option<&[u8]>) -> Vec<u8> {
    let grey = vec![128u8; (w * h * 4) as usize];
    let src = src.unwrap_or(&grey);
    let mut out = vec![0u8; (w * h * 4) as usize];
    let input = Image { data: src, width: w, height: h, stride: w * 4 };
    fx.process(&[input], ImageMut { data: &mut out, width: w, height: h, stride: w * 4 }, &FrameInfo::new(0.0, 0)).unwrap();
    out
}

/// Picks layer 0 on the left half and layer 1 on the right half.
const PICK_LAYER: &str = "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    gpufx_write(id, textureSampleLevel(pics, smp, uv, u32(uv.x >= 0.5), 0.0));
}";

#[test]
fn layers_and_grid_make_the_same_texture_array() {
    let Some(ctx) = gpu() else { return };
    let layers = package_dir("layers", &manifest(r#","textures":[{"name":"pics","layers":["a.png","b.png"]}]"#), PICK_LAYER, false);
    png(&layers.0.join("a.png"), 4, 4, |_, _| RED);
    png(&layers.0.join("b.png"), 4, 4, |_, _| BLUE);
    let grid = package_dir("grid", &manifest(r#","textures":[{"name":"pics","path":"atlas.png","grid":[2,1]}]"#), PICK_LAYER, false);
    png(&grid.0.join("atlas.png"), 8, 4, |x, _| if x < 4 { RED } else { BLUE });

    let (w, h) = (16, 6);
    let mut a = Effect::new(ctx.clone(), Package::open(&layers.0).unwrap()).unwrap();
    let out = run(&mut a, w, h, None);
    assert_eq!(out[..4], RED, "left reads layer 0");
    assert_eq!(out[((w - 1) * 4) as usize..][..4], BLUE, "right reads layer 1");
    let mut b = Effect::new(ctx, Package::open(&grid.0).unwrap()).unwrap();
    assert_eq!(run(&mut b, w, h, None), out, "a 2x1 grid is the same array as two layers");
}

#[test]
fn glsl_sees_texture_arrays() {
    let Some(ctx) = gpu() else { return };
    let shader = "layout(local_size_x = 8, local_size_y = 8) in;
void main() {
    uvec3 id = gl_GlobalInvocationID;
    if (!gpufx_in_bounds(id)) { return; }
    gpufx_write(id, textureLod(sampler2DArray(pics, smp), vec3(gpufx_uv(id), 1.0), 0.0));
}";
    let m = r#"{"api":2,"id":"t.tex","name":"Tex","textures":[{"name":"pics","path":"atlas.png","grid":[1,2]}],"passes":[{"shader":"main.glsl"}]}"#;
    let dir = package_dir("glsl", m, shader, true);
    png(&dir.0.join("atlas.png"), 2, 4, |_, y| if y < 2 { RED } else { BLUE });
    let mut fx = Effect::new(ctx, Package::open(&dir.0).unwrap()).unwrap();
    assert!(run(&mut fx, 8, 8, None).chunks(4).all(|p| p == BLUE));
}

#[test]
fn mipmaps_average_and_premultiply_clears_hidden_colour() {
    let Some(ctx) = gpu() else { return };
    // The last level of a 1-texel checkerboard is grey; layer 1 is red with zero alpha.
    let shader = "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let top = f32(textureNumLevels(pics) - 1u);
    if (id.x == 0u) { gpufx_write(id, textureSampleLevel(pics, smp, vec2f(0.0625), 0u, top)); }
    else { gpufx_write(id, textureLoad(pics, vec2i(0), 1u, 0)); }
}";
    let checker = |x: u32, y: u32| if (x + y).is_multiple_of(2) { [0, 0, 0, 255] } else { [255, 255, 255, 255] };
    let open = |tag: &str, flags: &str| {
        let textures = format!(r#","textures":[{{"name":"pics","layers":["c.png","r.png"]{flags}}}]"#);
        let dir = package_dir(tag, &manifest(&textures), shader, false);
        png(&dir.0.join("c.png"), 8, 8, checker);
        png(&dir.0.join("r.png"), 8, 8, |_, _| [255, 0, 0, 0]);
        Effect::new(ctx.clone(), Package::open(&dir.0).unwrap()).unwrap()
    };
    let mut plain = open("plain", "");
    let out = run(&mut plain, 2, 1, None);
    assert_eq!(out[..4], [0, 0, 0, 255], "one level: the top level is the image itself, got {:?}", &out[..4]);
    assert_eq!(out[4..8], [255, 0, 0, 0], "straight alpha keeps the hidden colour");

    let mut mipped = open("mipped", r#","mipmaps":true,"premultiply":true"#);
    let out = run(&mut mipped, 2, 1, None);
    assert!(out[..3].iter().all(|&c| (120..=136).contains(&c)) && out[3] == 255, "last mip level is grey, got {:?}", &out[..4]);
    assert_eq!(out[4..8], [0, 0, 0, 0], "premultiply turns (255,0,0,0) into (0,0,0,0)");
}

/// Samples `src` at its smallest mip level.
const TOP_LEVEL: &str = "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    gpufx_write(id, textureSampleLevel(src, smp, gpufx_uv(id), 20.0));
}";

fn checker_frame(w: u32, h: u32) -> Vec<u8> {
    (0..w * h).flat_map(|i| if (i % w + i / w).is_multiple_of(2) { [0, 0, 0, 255] } else { [255, 255, 255, 255] }).collect()
}

fn is_grey(out: &[u8]) -> bool {
    out.chunks(4).all(|p| p[..3].iter().all(|&c| (124..=132).contains(&c)) && p[3] == 255)
}

#[test]
fn input_mipmaps_are_made_every_frame() {
    let Some(ctx) = gpu() else { return };
    let (w, h) = (64, 32);
    let m = |mips: bool| manifest(&format!(r#","inputs":[{{"name":"src","mipmaps":{mips}}}]"#));
    let with = package_dir("in-mips", &m(true), TOP_LEVEL, false);
    let without = package_dir("in-nomips", &m(false), TOP_LEVEL, false);
    let checker = checker_frame(w, h);

    let mut fx = Effect::new(ctx.clone(), Package::open(&without.0).unwrap()).unwrap();
    assert_eq!(run(&mut fx, w, h, Some(&checker)), checker, "no mips: the level clamps to 0");
    let mut fx = Effect::new(ctx.clone(), Package::open(&with.0).unwrap()).unwrap();
    assert!(is_grey(&run(&mut fx, w, h, Some(&checker))), "the smallest level of a checkerboard is grey");
    // A new frame makes a new chain.
    let white = vec![255u8; (w * h * 4) as usize];
    assert_eq!(run(&mut fx, w, h, Some(&white)), white, "mips follow the frame");

    // 16-bit frames work in rgba16float.
    let deep: Vec<u8> = checker.iter().flat_map(|&c| [c, c]).collect();
    let mut out = vec![0u8; deep.len()];
    let frame = Frame {
        format: PixelFormat::Rgba64,
        width: w,
        height: h,
        planes: [&deep, &[], &[], &[]],
        strides: [w * 8, 0, 0, 0],
        color: ColorInfo::default(),
    };
    let target = FrameMut {
        format: PixelFormat::Rgba64,
        width: w,
        height: h,
        planes: [&mut out, &mut [], &mut [], &mut []],
        strides: [w * 8, 0, 0, 0],
        color: ColorInfo::default(),
    };
    fx.process_frames(&[frame], target, &FrameInfo::new(0.0, 0)).unwrap();
    let hi: Vec<u8> = out.chunks(2).map(|c| c[1]).collect();
    assert!(is_grey(&hi), "rgba16float mips");
}

#[test]
fn chained_effect_outputs_get_mips_when_read_as_mipmapped_inputs() {
    let Some(ctx) = gpu() else { return };
    let (w, h) = (64, 64);
    let copy = "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {
    if (gpufx_in_bounds(id)) { gpufx_write(id, textureLoad(src, vec2i(id.xy), 0)); }
}";
    let first = package_dir("chain-a", &manifest(""), copy, false);
    let m = |mips: bool| manifest(&format!(r#","inputs":[{{"name":"src","mipmaps":{mips}}}]"#));
    let second = package_dir("chain-b", &m(true), TOP_LEVEL, false);
    let flat = package_dir("chain-c", &m(false), TOP_LEVEL, false);
    let open = |d: &Dir| ("x".to_string(), Effect::new(ctx.clone(), Package::open(&d.0).unwrap()).unwrap());
    let checker = checker_frame(w, h);
    let run_chain = |chain: &mut EffectChain| {
        let mut out = vec![0u8; (w * h * 4) as usize];
        let input = Image { data: &checker, width: w, height: h, stride: w * 4 };
        chain.process(&[input], ImageMut { data: &mut out, width: w, height: h, stride: w * 4 }, &FrameInfo::new(0.0, 0)).unwrap();
        out
    };
    let mut mipped = EffectChain::new(vec![open(&first), open(&second)]).unwrap();
    assert!(is_grey(&run_chain(&mut mipped)), "the link between the effects has mips");
    let mut plain = EffectChain::new(vec![open(&first), open(&flat)]).unwrap();
    assert_eq!(run_chain(&mut plain), checker);
    // The mip chain of the link costs a third more than the plain link.
    let (a, b) = (mipped.memory(), plain.memory());
    assert_eq!(a.pass_textures, b.pass_textures);
    assert!(a.pass_texture_bytes > b.pass_texture_bytes && a.pass_texture_bytes < b.pass_texture_bytes * 3 / 2, "{a:?} vs {b:?}");
    assert_eq!(a.input_texture_bytes, b.input_texture_bytes, "the input pad has no mips");
}

fn open_err(dir: &Dir) -> String {
    match Package::open(&dir.0) {
        Ok(_) => panic!("{} must not open", dir.0.display()),
        Err(e) => e.to_string(),
    }
}

#[test]
fn image_sizes_are_checked_before_decoding() {
    let tex = |t: &str| manifest(&format!(r#","textures":[{t}]"#));
    let dir = package_dir("mismatch", &tex(r#"{"name":"t","layers":["a.png","b.png"]}"#), "", false);
    png(&dir.0.join("a.png"), 4, 4, |_, _| RED);
    png(&dir.0.join("b.png"), 4, 2, |_, _| RED);
    assert!(open_err(&dir).contains("layers must have one size"), "{}", open_err(&dir));

    let dir = package_dir("indivisible", &tex(r#"{"name":"t","path":"a.png","grid":[3,1]}"#), "", false);
    png(&dir.0.join("a.png"), 8, 4, |_, _| RED);
    assert!(open_err(&dir).contains("does not divide into a 3x1 grid"), "{}", open_err(&dir));

    let dir = package_dir("wide", &tex(r#"{"name":"t","path":"a.png"}"#), "", false);
    png(&dir.0.join("a.png"), 4097, 1, |_, _| RED);
    assert!(open_err(&dir).contains("4096 pixels a side"), "{}", open_err(&dir));

    // 17 layers of 4096x1024 decode to 68 M texels, above the 64 M budget.
    let layers = vec![r#""big.png""#; 17].join(",");
    let dir = package_dir("budget", &tex(&format!(r#"{{"name":"t","layers":[{layers}]}}"#)), "", false);
    png(&dir.0.join("big.png"), 4096, 1024, |_, _| [0; 4]);
    assert!(open_err(&dir).contains("texels"), "{}", open_err(&dir));

    let dir = package_dir("missing", &tex(r#"{"name":"t","layers":["a.png","nope.png"]}"#), "", false);
    png(&dir.0.join("a.png"), 4, 4, |_, _| RED);
    assert!(open_err(&dir).contains("nope.png"), "{}", open_err(&dir));
}

#[test]
fn api_1_packages_keep_api_1_rules() {
    let dir = package_dir(
        "api1",
        r#"{"id":"t.x","name":"X","textures":[{"name":"t","path":"a.png","mipmaps":true}],"passes":[{"shader":"main.wgsl"}]}"#,
        "",
        false,
    );
    png(&dir.0.join("a.png"), 4, 4, |_, _| RED);
    let err = open_err(&dir);
    assert!(err.contains("\"api\": 2"), "{err}");
    // A package for a newer runtime names the api, not its unknown fields.
    let dir = package_dir("api3", r#"{"api":3,"id":"t.x","name":"X","future":1,"passes":[{"shader":"main.wgsl"}]}"#, "", false);
    let err = open_err(&dir);
    assert!(err.contains("unsupported manifest api 3"), "{err}");
    assert!(matches!(Package::open(&dir.0), Err(Error::Manifest(_))));
}
