//! Effect graphs (`[0]split[a][b]; ...`) against the same effects run one by one.
//! Tests that need a device are skipped when none can be created.

mod common;

use std::path::PathBuf;
use std::sync::Arc;

use gpufx_core::{
    parse_effect_item, Effect, EffectChain, EffectGraph, Error, FrameInfo, GpuContext, Image, ImageMut, Package, Source, StreamInfo,
};

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

/// One device for every test, as in effects.rs.
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

fn effect(ctx: &Arc<GpuContext>, name: &str) -> Effect {
    Effect::new(ctx.clone(), Package::open(example(name)).unwrap()).unwrap()
}

/// Opens `name.zip` of a graph description from the example directories.
fn graph(ctx: &Arc<GpuContext>, text: &str) -> Result<EffectGraph, Error> {
    EffectGraph::parse(text, |path| {
        let name = path.strip_suffix(".zip").unwrap_or(path);
        Ok((name.to_string(), effect(ctx, name)))
    })
}

fn gradient(w: u32, h: u32) -> Vec<u8> {
    (0..w * h).flat_map(|i| [(i % w * 255 / w) as u8, (i / w * 255 / h) as u8, 128, 255]).collect()
}

const W: u32 = 67;
const H: u32 = 41;

fn img(data: &[u8]) -> Image<'_> {
    Image { data, width: W, height: H, stride: W * 4 }
}

/// Runs one effect alone on RGBA8 frames.
fn run(fx: &mut Effect, inputs: &[&[u8]], info: &FrameInfo) -> Vec<u8> {
    let mut out = vec![0u8; (W * H * 4) as usize];
    let imgs: Vec<Image> = inputs.iter().map(|d| img(d)).collect();
    fx.process(&imgs, ImageMut { data: &mut out, width: W, height: H, stride: W * 4 }, info).unwrap();
    out
}

fn run_graph(g: &mut EffectGraph, inputs: &[&[u8]], info: &FrameInfo) -> Vec<Vec<u8>> {
    let mut outs = vec![vec![0u8; (W * H * 4) as usize]; g.output_count()];
    let imgs: Vec<Image> = inputs.iter().map(|d| img(d)).collect();
    let targets = outs.iter_mut().map(|o| ImageMut { data: o, width: W, height: H, stride: W * 4 }).collect();
    g.process(&imgs, targets, info).unwrap();
    outs
}

const DIAMOND: &str = "[0]split[a][b]; [a]gaussian-blur.zip[ba]; [b]grayscale.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[out]";

#[test]
fn a_diamond_equals_its_effects_run_one_by_one() {
    let Some(ctx) = own_gpu() else { return };
    let src = gradient(W, H);
    let info = FrameInfo::new(0.5, 3);
    let blurred = run(&mut effect(&ctx, "gaussian-blur"), &[&src], &info);
    let gray = run(&mut effect(&ctx, "grayscale"), &[&src], &info);
    let mut vignette = effect(&ctx, "vignette");
    vignette.params_mut().set_str("strength", "0.7").unwrap();
    let vignetted = run(&mut vignette, &[&gray], &info);
    let mut crossfade = effect(&ctx, "crossfade");
    crossfade.params_mut().set_str("progress", "0.3").unwrap();
    let want = run(&mut crossfade, &[&blurred, &vignetted], &info);

    let mut g = graph(&ctx, DIAMOND).unwrap();
    assert_eq!((g.input_count(), g.output_count()), (1, 1));
    assert_eq!(g.output_names(), ["out"]);
    // Parameters by package label, by node label and bare.
    g.set_param_str("vignette.strength", "0.7").unwrap();
    g.set_param_str("progress", "0.3").unwrap();
    assert_eq!(g.find_param("gb.strength").unwrap(), g.find_param("vignette.strength").unwrap());
    assert_eq!(g.find_param("ba.radius").unwrap(), g.find_param("gaussian-blur.radius").unwrap());
    let out = run_graph(&mut g, &[&src], &info);
    assert_eq!(out[0], want, "the graph differs from its effects run one by one");

    // VRAM: blur.tmp, blur.out and the gray frame are alive together; vignette reuses
    // blur.tmp, crossfade the gray frame. Three pooled textures for five pass outputs.
    let texel = 4;
    let frame = (W * H) as u64 * texel;
    assert_eq!(g.memory_plan(&[(W, H)], false).unwrap(), (3, 3 * frame));
    let mem = g.memory();
    assert_eq!(mem.pass_textures, 3, "{mem:?}");
    assert_eq!(mem.pass_texture_bytes, 3 * frame);
    // One upload texture (straight RGBA is read directly), one readback.
    assert_eq!((mem.input_textures, mem.input_texture_bytes), (1, frame), "{mem:?}");
    assert_eq!(mem.readback_bytes, frame);
    // Deep frames double the bytes, not the count.
    assert_eq!(g.memory_plan(&[(W, H)], true).unwrap(), (3, 6 * frame));
    // Slots on the pooled textures, then the output bind groups: never again per frame,
    // as the context pool hands the graph back the textures it had.
    assert_eq!(g.allocations(), 2);
    run_graph(&mut g, &[&src], &info);
    assert_eq!(g.allocations(), 2);
}

#[test]
fn a_graph_with_several_outputs_equals_its_effects() {
    let Some(ctx) = gpu() else { return };
    let first = gradient(W, H);
    let second: Vec<u8> = first.chunks(4).flat_map(|p| [255 - p[0], p[2], 255 - p[1], 255]).collect();
    let info = FrameInfo::new(0.25, 1);
    let inverted = run(&mut effect(&ctx, "invert"), &[&first], &info);
    let mut wipe = effect(&ctx, "wipe-transition");
    wipe.params_mut().set_str("progress", "0.4").unwrap();
    let mut crossfade = effect(&ctx, "crossfade");
    crossfade.params_mut().set_str("progress", "0.6").unwrap();
    let mixed = run(&mut crossfade, &[&inverted, &second], &info);
    let wiped = run(&mut wipe, &[&mixed, &second], &info);

    // [inv] and [x] are both read by a node and written out; [keep] is input 0 itself.
    let text = "[0]split[a][keep]; [a]invert.zip[i]; [i]split[inv][i2]; [1]split[s1][s2]; [i2][s1]crossfade.zip[x]; [x]split[xo][x2]; [x2][s2]wipe-transition.zip[w]";
    let mut g = graph(&ctx, text).unwrap();
    assert_eq!(g.input_count(), 2);
    assert_eq!(g.output_names(), ["keep", "inv", "xo", "w"]);
    assert_eq!(g.output_source(0), Source::Input(0));
    assert_eq!((0..4).map(|k| g.output_pad(k)).collect::<Vec<_>>(), [0, 0, 0, 0]);
    g.set_param_str("crossfade.progress", "0.6").unwrap();
    g.set_param_str("w.progress", "0.4").unwrap();
    let outs = run_graph(&mut g, &[&first, &second], &info);
    assert_eq!(outs[0], first);
    assert_eq!(outs[1], inverted);
    assert_eq!(outs[2], mixed);
    assert_eq!(outs[3], wiped);
    // Outputs read by later nodes are kept until readback: invert, crossfade and wipe
    // outputs are all alive at the end.
    assert_eq!(g.memory().pass_textures, 3);
    assert_eq!(g.memory().readback_bytes, 4 * (W * H * 4) as u64);

    // Bypass: every output is its pad converted.
    let mut outs = vec![vec![0u8; (W * H * 4) as usize]; 4];
    let frames = [img(&first).into(), img(&second).into()];
    let mut targets: Vec<gpufx_core::FrameMut> =
        outs.iter_mut().map(|o| ImageMut { data: o, width: W, height: H, stride: W * 4 }.into()).collect();
    g.convert(&frames, &mut targets).unwrap();
    drop(targets);
    assert!(outs.iter().all(|o| *o == first));
}

#[test]
fn a_linear_graph_is_a_chain() {
    let Some(ctx) = gpu() else { return };
    let src = gradient(W, H);
    let info = FrameInfo::new(0.0, 0);
    let mut chain =
        EffectChain::new(vec![("grayscale".into(), effect(&ctx, "grayscale")), ("vignette".into(), effect(&ctx, "vignette"))]).unwrap();
    let mut want = vec![0u8; src.len()];
    chain.process(&[img(&src)], ImageMut { data: &mut want, width: W, height: H, stride: W * 4 }, &info).unwrap();
    let mut g = graph(&ctx, "[0] grayscale.zip | vignette.zip [out]").unwrap();
    assert_eq!(g.param_names(), chain.param_names());
    assert_eq!(run_graph(&mut g, &[&src], &info)[0], want);
    // The chain pools like the graph: two pass outputs ping-pong.
    assert_eq!(chain.memory().pass_textures, 2);
}

#[test]
fn graph_mistakes_are_explained() {
    let Some(ctx) = gpu() else { return };
    let err = |text: &str| match graph(&ctx, text) {
        Ok(_) => panic!("`{text}` was accepted"),
        Err(e) => e.to_string(),
    };
    let cases = [
        ("[0][b]crossfade.zip[a]; [a]split[b][out]", "cycle through [a]"),
        ("[0]invert.zip[a]; [b]invert.zip[c]", "`[b]` is read but never written"),
        ("[0]split[a][b]; [a]invert.zip[a]", "`[a]` is written twice"),
        ("[0]invert.zip[a]; [a]split[b]; [a][b]crossfade.zip[c]", "`[a]` is read twice"),
        ("[1]invert.zip[a]", "input pad `[0]` is not read"),
        ("[0]crossfade.zip[a]", "takes 2 inputs, the node gives it 1"),
        ("[0]invert.zip|crossfade.zip[a]", "only the first effect"),
        ("[0][1]invert.zip[a]", "takes 1 inputs, the node gives it 2"),
        ("[0]invert.zip[a][b]", "writes one label, got 2"),
        ("[0]invert.zip", "has no output label"),
        ("invert.zip[a]", "has no input label"),
        ("[0]invert.zip[1]", "names an input pad"),
        ("[0]invert.zip[a b]", "bad label"),
        ("[0]invert.zip[a.b]", "clash with `label.param`"),
        ("[0]invert.zip[a", "unclosed"),
        ("[0]null[a][b]", "`null` writes one label"),
        ("[0]split[a][b]", "runs no effect"),
        ("[01]invert.zip[a]", "without leading zeros"),
        ("[0]invert.zip[a] x", "unexpected `x`"),
        (" ; ", "empty"),
    ];
    for (text, want) in cases {
        let got = err(text);
        assert!(got.contains(want), "`{text}`: {got}");
    }

    // Size and format rules hold at every node: crossfade wants equal sizes.
    let g = graph(&ctx, "[0]invert.zip[a]; [a][1]crossfade.zip[out]").unwrap();
    let s = |w| StreamInfo { format: Some("rgba"), width: w, height: 8 };
    g.check_inputs(&[s(8), s(8)]).unwrap();
    let got = g.check_inputs(&[s(8), s(9)]).unwrap_err().to_string();
    assert!(got.contains("must equal the first input"), "{got}");
    let got = g.check_inputs(&[s(8)]).unwrap_err().to_string();
    assert!(got.contains("takes 2 input(s)"), "{got}");
    // Unknown names list the effects and node labels.
    let got = g.find_param("nothing.amount").unwrap_err().to_string();
    assert!(got.contains("invert, crossfade, a, out"), "{got}");
}

/// Switches the effects `node` names on or off.
fn switch(g: &mut EffectGraph, node: &str, on: bool) {
    for k in g.find_node(node).unwrap() {
        g.set_node_enabled(k, on).unwrap();
    }
}

#[test]
fn effects_switched_off_pass_their_input_through() {
    let Some(ctx) = own_gpu() else { return };
    let src = gradient(W, H);
    let info = FrameInfo::new(0.5, 3);
    let gray = run(&mut effect(&ctx, "grayscale"), &[&src], &info);
    let inv = run(&mut effect(&ctx, "invert"), &[&src], &info);
    let gray_inv = run(&mut effect(&ctx, "invert"), &[&gray], &info);
    let vig = |input: &[u8]| run(&mut effect(&ctx, "vignette"), &[input], &info);

    let mut g = graph(&ctx, "[0]grayscale.zip|invert.zip|vignette.zip[out]").unwrap();
    let full = run_graph(&mut g, &[&src], &info).remove(0);
    assert_eq!(full, vig(&gray_inv));
    let allocations = g.allocations();
    // The middle, the first, the last, then all of them.
    switch(&mut g, "invert", false);
    assert!(!g.node_enabled(1) && !g.all_nodes_disabled());
    assert_eq!(run_graph(&mut g, &[&src], &info)[0], vig(&gray));
    switch(&mut g, "invert", true);
    switch(&mut g, "0", false);
    assert_eq!(run_graph(&mut g, &[&src], &info)[0], vig(&inv));
    switch(&mut g, "0", true);
    switch(&mut g, "vignette", false);
    assert_eq!(run_graph(&mut g, &[&src], &info)[0], gray_inv);
    for k in 0..3 {
        g.set_node_enabled(k, false).unwrap();
    }
    assert!(g.all_nodes_disabled());
    assert_eq!(run_graph(&mut g, &[&src], &info)[0], src, "all off is the input");
    // Toggling plans and binds nothing again: the copies reuse their bind groups.
    let binds = g.frame_binds();
    for on in [true, false, true, false] {
        switch(&mut g, "1", on);
        run_graph(&mut g, &[&src], &info);
    }
    assert_eq!(g.allocations(), allocations);
    assert_eq!(g.frame_binds(), binds, "the copy of effect 1 was made when it was first off");
    for k in 0..3 {
        g.set_node_enabled(k, true).unwrap();
    }
    assert_eq!(run_graph(&mut g, &[&src], &info)[0], full);
}

#[test]
fn switched_effects_are_named_like_parameters() {
    let Some(ctx) = gpu() else { return };
    let src = gradient(W, H);
    let info = FrameInfo::new(0.0, 0);
    let inv = run(&mut effect(&ctx, "invert"), &[&src], &info);

    // One package twice: by index only.
    let mut g = graph(&ctx, "[0]invert.zip|invert.zip[out]").unwrap();
    let got = g.find_node("invert").unwrap_err().to_string();
    assert!(got.contains("names 2 effects") && got.contains("`0.enable`"), "{got}");
    assert!(g.find_node("").unwrap_err().to_string().contains("say which one"));
    assert!(g.find_node("2").is_err() && g.find_node("nothing").is_err());
    assert!(g.set_node_enabled(2, false).is_err());
    switch(&mut g, "1", false);
    assert_eq!(run_graph(&mut g, &[&src], &info)[0], inv);
    switch(&mut g, "0", false);
    assert_eq!(run_graph(&mut g, &[&src], &info)[0], src);

    // A bare `enable` is the only effect of a single one.
    let single = graph(&ctx, "[0]invert.zip[out]").unwrap();
    assert_eq!(single.find_node("").unwrap(), [0]);

    // A graph statement's output label switches every effect of the statement; an
    // effect switched off still feeds its readers and the outputs.
    let text = "[0]split[a][b]; [a]invert.zip[i]; [i]split[inv][i2]; [b]grayscale.zip|vignette.zip[y]; [i2][y]crossfade.zip[out]";
    let mut g = graph(&ctx, text).unwrap();
    assert_eq!(g.find_node("y").unwrap(), [1, 2]);
    assert_eq!(g.find_node("i").unwrap(), g.find_node("invert").unwrap());
    g.set_param_str("progress", "0.3").unwrap();
    let mut crossfade = effect(&ctx, "crossfade");
    crossfade.params_mut().set_str("progress", "0.3").unwrap();
    switch(&mut g, "y", false);
    assert_eq!(run_graph(&mut g, &[&src], &info), [inv.clone(), run(&mut crossfade, &[&inv, &src], &info)]);
    switch(&mut g, "y", true);
    switch(&mut g, "i", false);
    let gray = run(&mut effect(&ctx, "grayscale"), &[&src], &info);
    let vig = run(&mut effect(&ctx, "vignette"), &[&gray], &info);
    assert_eq!(run_graph(&mut g, &[&src], &info), [src.clone(), run(&mut crossfade, &[&src, &vig], &info)]);
    // Every effect off: each output is its input pad, as the bypass writes it.
    for k in 0..4 {
        g.set_node_enabled(k, false).unwrap();
    }
    assert!(g.all_nodes_disabled());
    assert_eq!(run_graph(&mut g, &[&src], &info), [src.clone(), src.clone()]);
}

#[test]
fn a_multi_pass_effect_switched_off_copies_an_input_only_its_first_pass_reads() {
    let Some(ctx) = own_gpu() else { return };
    let src = gradient(W, H);
    let info = FrameInfo::new(0.5, 3);
    let gray = run(&mut effect(&ctx, "grayscale"), &[&src], &info);
    let inv = run(&mut effect(&ctx, "invert"), &[&gray], &info);

    // The blur has two passes and its last one reads the first one's output, not its
    // input: the pooled texture of the invert output must stay alive up to the copy.
    let mut g = graph(&ctx, "[0]grayscale.zip|invert.zip|gaussian-blur.zip|vignette.zip[out]").unwrap();
    switch(&mut g, "gaussian-blur", false);
    let vig = run(&mut effect(&ctx, "vignette"), &[&inv], &info);
    assert_eq!(run_graph(&mut g, &[&src], &info)[0], vig);
    // As the last effect: the copy writes the output.
    let mut g = graph(&ctx, "[0]grayscale.zip|invert.zip|gaussian-blur.zip[out]").unwrap();
    switch(&mut g, "gaussian-blur", false);
    assert_eq!(run_graph(&mut g, &[&src], &info)[0], inv);
}

/// A two-pass effect of two inputs whose second input only the first pass reads (the
/// sum of both, halved), as a package directory removed when dropped.
struct TwoInputPackage(PathBuf);

impl TwoInputPackage {
    fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("gpufx-two-inputs-{}-{n}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        let manifest = r#"{"api":1,"id":"t.mix","name":"Mix","inputs":[{"name":"a"},{"name":"b","same_size":true}],
            "passes":[{"shader":"mix.wgsl","inputs":["a","b"],"output":"tmp"},{"shader":"copy.wgsl","inputs":["tmp"],"output":"out"}]}"#;
        std::fs::write(dir.join("manifest.json"), manifest).unwrap();
        let mix = "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    gpufx_write(id, (textureLoad(a, vec2i(id.xy), 0) + textureLoad(b, vec2i(id.xy), 0)) * 0.5);
}";
        let copy = "@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    gpufx_write(id, textureLoad(tmp, vec2i(id.xy), 0));
}";
        std::fs::write(dir.join("mix.wgsl"), mix).unwrap();
        std::fs::write(dir.join("copy.wgsl"), copy).unwrap();
        TwoInputPackage(dir)
    }

    /// A graph of examples and `mix.zip`.
    fn graph(&self, ctx: &Arc<GpuContext>, text: &str) -> EffectGraph {
        EffectGraph::parse(text, |path| {
            let name = path.trim_end_matches(".zip");
            let dir = if name == "mix" { self.0.clone() } else { example(name) };
            Ok((name.to_string(), Effect::new(ctx.clone(), Package::open(dir)?)?))
        })
        .unwrap()
    }
}

impl Drop for TwoInputPackage {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).ok();
    }
}

#[test]
fn an_effect_switched_off_passes_the_input_bypass_picks() {
    let Some(ctx) = own_gpu() else { return };
    let src = gradient(W, H);
    let info = FrameInfo::new(0.5, 3);
    let inv = run(&mut effect(&ctx, "invert"), &[&src], &info);
    let gray = run(&mut effect(&ctx, "grayscale"), &[&src], &info);
    let vig = |input: &[u8]| run(&mut effect(&ctx, "vignette"), &[input], &info);

    // The second input of the two-pass mix is read by its first pass only: switched off
    // and passing it, the mix copies it after its last pass, so it must still be alive
    // then (its pooled texture not handed to the mix output).
    let mix = TwoInputPackage::new();
    for (text, tail) in [
        ("[0]split[a][b]; [a]invert.zip[i]; [b]grayscale.zip[g]; [i][g]mix.zip[out]", false),
        ("[0]split[a][b]; [a]invert.zip[i]; [b]grayscale.zip[g]; [i][g]mix.zip|vignette.zip[out]", true),
    ] {
        let mut g = mix.graph(&ctx, text);
        let k = g.find_node("mix").unwrap()[0];
        let then = |x: &[u8]| if tail { vig(x) } else { x.to_vec() };
        g.set_node_enabled(k, false).unwrap();
        assert_eq!(run_graph(&mut g, &[&src], &info)[0], then(&inv), "`{text}`: bypass 0 is the first input");
        g.set_node_bypass(k, 1).unwrap();
        assert_eq!(g.node_bypass(k), 1);
        assert_eq!(run_graph(&mut g, &[&src], &info)[0], then(&gray), "`{text}`: bypass 1 is the second input");
        g.set_node_bypass(k, 0).unwrap();
        assert_eq!(run_graph(&mut g, &[&src], &info)[0], then(&inv), "`{text}`: back to the first input");
        let got = g.set_node_bypass(k, 2).unwrap_err().to_string();
        assert!(got.contains("bypass 2") && got.contains("2 inputs"), "{got}");
        assert!(g.set_node_bypass(9, 0).is_err());
    }

    // Two input pads: the outputs of the graph bypassed follow the choice.
    let mut g = graph(&ctx, "[0][1]crossfade.zip[out]").unwrap();
    assert_eq!(g.bypass_pad(0), 0);
    g.set_node_bypass(0, 1).unwrap();
    assert_eq!(g.bypass_pad(0), 0, "BypassPad::First ignores the effects");
    g.set_bypass_pad(gpufx_core::BypassPad::Nodes).unwrap();
    assert_eq!(g.bypass_pad(0), 1);
    g.set_bypass_pad(gpufx_core::BypassPad::Pad(0)).unwrap();
    assert_eq!(g.bypass_pad(0), 0);
    assert!(g.set_bypass_pad(gpufx_core::BypassPad::Pad(2)).unwrap_err().to_string().contains("2 inputs"));
    // Switched off with progress anywhere: the second clip.
    g.set_node_enabled(0, false).unwrap();
    assert_eq!(run_graph(&mut g, &[&src, &inv], &info)[0], inv);
}

#[test]
fn inline_options_are_split_unescaped_and_named() {
    let opts = |pairs: &[(&str, &str)]| pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect::<Vec<_>>();
    let (path, o) = parse_effect_item(" wipe.zip=progress=clip((t-1)/1.5,0,1):angle=45 ").unwrap();
    assert_eq!(path, "wipe.zip");
    assert_eq!(o, opts(&[("progress", "clip((t-1)/1.5,0,1)"), ("angle", "45")]));
    assert_eq!(parse_effect_item("a.zip").unwrap(), ("a.zip".to_string(), Vec::new()));
    // `\` escapes the separators, quotes keep them; a `\` before anything else stays (Windows paths).
    let (path, o) = parse_effect_item(r"C:\fx\a\=b.zip=text=a\:b\|c\;d\[e\]f\=g:color='1:2|3'").unwrap();
    assert_eq!(path, r"C:\fx\a=b.zip");
    assert_eq!(o, opts(&[("text", "a:b|c;d[e]f=g"), ("color", "1:2|3")]));
    assert_eq!(parse_effect_item(r"a.zip=k=\\\'").unwrap().1, opts(&[("k", r"\'")]));
    let err = |item: &str| parse_effect_item(item).unwrap_err().to_string();
    assert!(err("a.zip=k=1:k=2").contains("key `k` given twice"), "{}", err("a.zip=k=1:k=2"));
    assert!(err("a.zip=enable=1:enable=0").contains("given twice"));
    assert!(err("a.zip=1").contains("is not key=value"), "{}", err("a.zip=1"));
    assert!(err("a.zip==1").contains("has no key"));
    assert!(err("a.zip=k='1").contains("unclosed `'`"));
}

#[test]
fn inline_options_set_parameters_and_keep_the_rest_for_the_caller() {
    let Some(ctx) = gpu() else { return };
    let g = graph(
        &ctx,
        r"[0]split[a][b]; [a]gaussian-blur.zip=radius=8[ba]; [b]grayscale.zip|vignette.zip=strength=0.25:radius=t/2[gb];
          [ba][gb]crossfade.zip=progress=clip((t-1)/1.5,0,1):enable=between(t,1,3):bypass=auto[x]",
    )
    .unwrap();
    let fx = g.effects();
    assert_eq!(fx[0].params().get("radius").unwrap().0[0], 8.0);
    assert_eq!(fx[2].params().get("strength").unwrap().0[0], 0.25);
    let o = g.inline_options();
    assert_eq!(o.len(), 4);
    assert!(o[1].is_empty());
    assert_eq!(o[2][1], ("radius".to_string(), "t/2".to_string()));
    let keys: Vec<&str> = o[3].iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(keys, ["progress", "enable", "bypass"]);
    assert_eq!(o[3][0].1, "clip((t-1)/1.5,0,1)");

    // A chain written as one string takes the same options.
    let chain = EffectChain::parse("invert.zip | vignette.zip=strength=0.5:enable=gt(t,2)", |path| {
        let name = path.strip_suffix(".zip").unwrap_or(path);
        Ok((name.to_string(), effect(&ctx, name)))
    })
    .unwrap();
    assert_eq!(chain.effects()[1].params().get("strength").unwrap().0[0], 0.5);
    assert_eq!(chain.graph().inline_options()[1].len(), 2);
    assert!(chain.graph().inline_options()[0].is_empty());
}

#[test]
fn inline_option_mistakes_are_explained() {
    let Some(ctx) = gpu() else { return };
    let cases = [
        ("[0]vignette.zip=amount=1[a]", "effect `vignette.zip` has no parameter `amount` (keys: strength, radius, color, enable, bypass)"),
        ("[0]vignette.zip=strength=1:strength=2[a]", "key `strength` given twice"),
        ("[0]vignette.zip=bypass=1[a]", "bypass is 0 or auto"),
        ("[0]vignette.zip=0.5[a]", "is not key=value"),
        // Names given to a node of several effects belong to one of them.
        ("[0]invert.zip|vignette.zip=amount=1[a]", "has no parameter `amount`"),
    ];
    for (text, want) in cases {
        let got = graph(&ctx, text).err().map(|e| e.to_string()).unwrap_or_default();
        assert!(got.contains(want), "`{text}`: {got}");
    }
    let got = EffectChain::parse("invert.zip=strength=1", |path| Ok(("invert".into(), effect(&ctx, path.trim_end_matches(".zip")))))
        .err()
        .map(|e| e.to_string())
        .unwrap_or_default();
    assert!(got.contains("effect `invert.zip` has no parameter `strength`"), "{got}");
}
