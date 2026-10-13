//! The frame resource pool of a context, shared by every graph on it (as the gpufx
//! filters of one FFmpeg filter graph share one device). Tests that need a device are
//! skipped when none can be created.

use std::path::PathBuf;
use std::sync::Arc;

use gpufx_core::{Backend, Effect, EffectGraph, FrameInfo, GpuContext, Image, ImageMut, Package};

fn examples() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects")
}

/// A device of its own, so the pool statistics see only this test's graphs.
fn own_gpu() -> Option<Arc<GpuContext>> {
    match GpuContext::new(Backend::Auto) {
        Ok(ctx) => Some(ctx),
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    }
}

/// One test at a time: each makes a device of its own.
fn serial() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    LOCK.lock().unwrap_or_else(|p| p.into_inner())
}

fn graph(ctx: &Arc<GpuContext>, text: &str) -> EffectGraph {
    EffectGraph::parse(text, |path| {
        let name = path.strip_suffix(".zip").unwrap_or(path);
        Ok((name.to_string(), Effect::new(ctx.clone(), Package::open(examples().join(name))?)?))
    })
    .unwrap()
}

fn gradient(w: u32, h: u32, seed: u32) -> Vec<u8> {
    (0..w * h).flat_map(|i| [((i % w + seed) * 255 / (w + seed)) as u8, (i / w * 255 / h) as u8, (seed * 37) as u8, 255]).collect()
}

fn run(g: &mut EffectGraph, data: &[u8], w: u32, h: u32, frame: u64) -> Vec<u8> {
    let mut out = vec![0u8; data.len()];
    let info = FrameInfo::new(frame as f64 / 25.0, frame);
    g.process(
        &[Image { data, width: w, height: h, stride: w * 4 }],
        vec![ImageMut { data: &mut out, width: w, height: h, stride: w * 4 }],
        &info,
    )
    .unwrap();
    out
}

/// What a graph borrows per frame: pass textures, upload textures and output words (as
/// many bytes as its readback buffer, borrowed too).
fn own_bytes(g: &EffectGraph) -> u64 {
    let m = g.memory();
    m.pass_texture_bytes + m.input_texture_bytes + m.readback_bytes
}

#[test]
fn graphs_in_a_row_share_one_readback_buffer() {
    let _serial = serial();
    let Some(ctx) = own_gpu() else { return };
    let (w, h) = (64, 36);
    let src = gradient(w, h, 2);
    let mut first = graph(&ctx, "[0]invert.zip[out]");
    let want = run(&mut first, &src, w, h, 0);
    let one = ctx.pool_stats();
    // The readback buffer is pooled with the output words of the same size.
    assert!(one.idle_bytes >= own_bytes(&first) + first.memory().readback_bytes, "{one:?}");
    let mut graphs: Vec<EffectGraph> = (0..7).map(|_| graph(&ctx, "[0]invert.zip[out]")).collect();
    for f in 0..3 {
        for g in &mut graphs {
            assert_eq!(run(g, &src, w, h, f), want);
        }
    }
    let all = ctx.pool_stats();
    assert_eq!(all.borrowed, 0, "the readback buffer is given back once unmapped");
    assert_eq!(all.created, one.created, "the later graphs borrow the first one's buffers");
}

const EFFECTS: [&str; 8] = ["gaussian-blur", "invert", "sharpen", "vignette", "gaussian-blur", "grayscale", "pixelate", "sepia"];

#[test]
fn separate_graphs_share_the_pool_of_their_device() {
    let _serial = serial();
    let (w, h) = (320, 180);
    let src = gradient(w, h, 0);

    // One graph running the eight effects.
    let Some(one) = own_gpu() else { return };
    let chain_text = format!("[0]{}[out]", EFFECTS.iter().map(|e| format!("{e}.zip")).collect::<Vec<_>>().join("|"));
    let mut chain = graph(&one, &chain_text);
    let mut want = Vec::new();
    for f in 0..4 {
        want = run(&mut chain, &src, w, h, f);
    }
    let one_peak = one.pool_stats().peak_bytes;

    // The same effects as eight graphs, as eight filters in a row, frame by frame.
    let Some(ctx) = own_gpu() else { return };
    let mut graphs: Vec<EffectGraph> = EFFECTS.iter().map(|e| graph(&ctx, &format!("[0]{e}.zip[out]"))).collect();
    let mut created = None;
    let mut allocations = Vec::new();
    for f in 0..6 {
        let mut frame = src.clone();
        for g in &mut graphs {
            frame = run(g, &frame, w, h, f);
        }
        if f < 4 {
            assert_eq!(frame, want, "frame {f}: the separate graphs differ from the chain");
        }
        let stats = ctx.pool_stats();
        assert_eq!(stats.borrowed, 0, "everything is given back after each frame");
        // Nothing new after the first frame: each graph gets its textures back.
        if f == 1 {
            created = Some(stats.created);
            allocations = graphs.iter().map(|g| g.allocations()).collect();
        } else if f > 1 {
            assert_eq!(Some(stats.created), created, "frame {f}");
            assert_eq!(graphs.iter().map(|g| g.allocations()).collect::<Vec<_>>(), allocations, "frame {f}");
        }
    }
    let shared_peak = ctx.pool_stats().peak_bytes;
    // What the graphs held each on its own before the pool, the readback buffers aside.
    let unshared: u64 = graphs.iter().map(own_bytes).sum();
    let rgba = w as u64 * h as u64 * 4;
    eprintln!("pooled bytes: one graph {one_peak}, eight graphs {shared_peak}; unshared eight graphs {unshared}");
    assert!(shared_peak <= one_peak + rgba, "eight graphs pool {shared_peak} bytes, one graph {one_peak}");
    assert!(shared_peak * 3 < unshared, "eight graphs pool {shared_peak} bytes, unshared {unshared}");
}

#[test]
fn interleaved_graphs_give_what_they_give_alone() {
    let _serial = serial();
    let Some(ctx) = own_gpu() else { return };
    let (w, h) = (67, 41);
    let texts = ["[0]gaussian-blur.zip|invert.zip|gaussian-blur.zip[out]", "[0]sharpen.zip|gaussian-blur.zip|vignette.zip[out]"];
    let frames: Vec<Vec<u8>> = (0..4).map(|s| gradient(w, h, s)).collect();
    // Alone: each graph runs every frame before the other one starts.
    let want: Vec<Vec<Vec<u8>>> = texts
        .iter()
        .map(|t| {
            let mut g = graph(&ctx, t);
            frames.iter().enumerate().map(|(f, d)| run(&mut g, d, w, h, f as u64)).collect()
        })
        .collect();
    // Interleaved: the pool hands the second graph the textures the first just used.
    let mut gs: Vec<EffectGraph> = texts.iter().map(|t| graph(&ctx, t)).collect();
    for (f, d) in frames.iter().enumerate() {
        for (k, g) in gs.iter_mut().enumerate() {
            assert_eq!(run(g, d, w, h, f as u64), want[k][f], "graph {k}, frame {f}");
        }
    }
}

#[test]
fn graphs_on_two_threads_share_the_pool() {
    let _serial = serial();
    let Some(ctx) = own_gpu() else { return };
    let (w, h) = (96, 54);
    let texts = ["[0]gaussian-blur.zip|invert.zip[out]", "[0]sharpen.zip|vignette.zip|gaussian-blur.zip[out]"];
    let frames: Vec<Vec<u8>> = (0..3).map(|s| gradient(w, h, s)).collect();
    let want: Vec<Vec<Vec<u8>>> = texts
        .iter()
        .map(|t| {
            let mut g = graph(&ctx, t);
            frames.iter().enumerate().map(|(f, d)| run(&mut g, d, w, h, f as u64)).collect()
        })
        .collect();
    std::thread::scope(|s| {
        for (k, t) in texts.iter().enumerate() {
            let (ctx, frames, want) = (&ctx, &frames, &want);
            s.spawn(move || {
                let mut g = graph(ctx, t);
                for i in 0..40 {
                    let f = i % frames.len();
                    assert_eq!(run(&mut g, &frames[f], w, h, f as u64), want[k][f], "graph {k}, run {i}");
                }
            });
        }
    });
    assert_eq!(ctx.pool_stats().borrowed, 0);
}

#[test]
fn a_new_size_frees_the_textures_of_the_old_one() {
    let _serial = serial();
    let Some(ctx) = own_gpu() else { return };
    let mut g = graph(&ctx, "[0]gaussian-blur.zip|invert.zip[out]");
    let big = gradient(160, 90, 1);
    for f in 0..3 {
        run(&mut g, &big, 160, 90, f);
    }
    let before = ctx.pool_stats();
    let small = gradient(32, 18, 1);
    for f in 0..8 {
        run(&mut g, &small, 32, 18, f);
    }
    let after = ctx.pool_stats();
    assert_eq!(after.borrowed, 0);
    // Only the small textures are left.
    assert!(after.idle_bytes * 10 < before.idle_bytes, "{before:?} -> {after:?}");
}
