// Collage Shift, pass 1 (top row; keep in sync with strip-bottom.wgsl): one row of the clip tiled sideways into a widening strip, smeared by a directional blur.

// This file renders the upper row; the lower row uses the same code with TOP_ROW = false.
const TOP_ROW: bool = true;

// The animation runs over 2 s of timeline.
const TIMELINE: f32 = 2.0;

fn timeline_now() -> f32 { return clamp(params.progress, 0.0, 1.0) * TIMELINE; }

// One axis of a cubic bezier through (0, 0), (a, .), (b, .), (1, end) at curve parameter s.
fn bezier_axis(a: f32, b: f32, end: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + end * s * s * s;
}

// Keyframe easing: find s where the x axis reaches u, return the y axis there.
// `end` is 1 for an ordinary segment and 0 for a segment whose two values are equal
// (then the curve only adds a bump on top of the held value).
fn ease(k: vec4f, end: f32, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(k.x, k.z, 1.0, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(k.y, k.w, end, 0.5 * (lo + hi));
}

// One keyframe segment: keeps `cur` before t0, eases from v0 to v1 inside, holds v1 after.
fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, k: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return v0 + (v1 - v0) * ease(k, 1.0, (t - t0) / (t1 - t0));
}

// A segment between two equal values: the value plus the curve's own bump.
fn key_bump(cur: f32, t: f32, t0: f32, t1: f32, v: f32, k: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v; }
    return v + ease(k, 0.0, (t - t0) / (t1 - t0));
}

// How many clip widths are added on each side of the row.
fn spread(t: f32) -> f32 {
    return key(0.0, t, 0.133333, 0.766667, 0.0, 2.0, vec4f(0.166666667, 0.166666667, 0.66666667, 1.0));
}

fn blur_strength(t: f32) -> f32 {
    var v = 0.0;
    if (TOP_ROW) {
        v = key(v, t, 0.133333, 0.5, 0.0, 21.0, vec4f(0.201866692, 0.459737807, 0.563190536, -0.14128636));
        v = key(v, t, 0.5, 1.133333, 21.0, 50.0, vec4f(0.33948418, 1.109441332, 0.843111118, 1.0));
        v = key(v, t, 1.133333, 1.233333, 50.0, 31.0, vec4f(0.166666667, 0.0, 0.583333333, -0.789473684));
        v = key(v, t, 1.233333, 1.333333, 31.0, 30.0, vec4f(0.416666667, 34.0, 0.833333333, 1.0));
        v = key(v, t, 1.333333, 1.533333, 30.0, 31.0, vec4f(0.166666667, 0.0, 0.833333333, 1.0));
    } else {
        v = key(v, t, 0.133333, 0.5, 0.0, 21.0, vec4f(0.166666667, 0.166666667, 0.66666667, 1.0));
        v = key(v, t, 0.5, 1.133333, 21.0, 50.0, vec4f(0.33333333, 0.0, 0.833333333, 1.0));
        v = key(v, t, 1.133333, 1.233333, 50.0, 30.0, vec4f(0.166666667, 0.0, 0.583333333, -0.7));
        v = key_bump(v, t, 1.233333, 1.333333, 30.0, vec4f(0.416666667, -34.0, 0.833333333, 0.0));
    }
    return clamp(v, 0.0, 1000.0);
}

// Blur direction in degrees: starts vertical, then swings round to horizontal.
fn blur_angle(t: f32) -> f32 {
    var end = 270.0;
    if (TOP_ROW) { end = 450.0; }
    return key(180.0, t, 0.5, 0.6, 180.0, end, vec4f(0.33333333, 0.0, 0.833333333, 0.833333333));
}

// Blur taps per side for a strength, and the working-resolution factor that goes with it.
fn tap_budget(strength: f32) -> vec2f {
    var scale = 0.125;
    var bias = 100.0;
    var s = 0.8;
    if (strength <= 10.0) { scale = 0.8; bias = 0.0; s = 1.0; }
    else if (strength <= 50.0) { scale = 0.7; bias = 2.0; s = 0.78; }
    else if (strength <= 200.0) { scale = 0.5; bias = 10.0; s = 0.66; }
    else if (strength <= 500.0) { scale = 0.25; bias = 60.0; s = 0.7; }
    var n = (scale * strength + bias) * s;
    if (n < 2.0) { n = floor(n + 0.5); }
    return vec2f(n, scale);
}

// Tap multiplier from the quality setting (0..1).
fn quality_gain(q: f32) -> f32 {
    let x = q * 2.0 - 1.0;
    if (x < 0.0) { return pow(10.0, x); }
    return x * 2.0 + 1.0;
}

// The widened row: `w` extra clip widths each side squeezed into the 0..1 frame, the clip repeated.
fn widened(q: vec2f, w: f32) -> vec4f {
    let x = q.x * (1.0 + 2.0 * w) - w;
    return textureSampleLevel(first, smp, vec2f(fract(x), fract(q.y)), 0.0);
}

// Small per-pixel jitter in -1..1.
fn jitter(p: vec2f) -> f32 {
    var a = fract(vec3f(p.x, p.y, p.x) * 0.1031);
    a += dot(a, a.yzx + 33.33);
    return fract(fract((a.x + a.y) * a.z)) * 2.0 - 1.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = timeline_now();
    let uv = gpufx_uv(id);
    let w = spread(t);
    let strength = blur_strength(t);
    var quality = 1.0;
    var dither = 0.03;
    if (TOP_ROW) { quality = 0.5; dither = 0.0; }
    let budget = tap_budget(strength);
    let taps = budget.x * quality_gain(quality);
    if (taps < 1e-5) {
        gpufx_write(id, widened(uv, w));
        return;
    }
    // Step between taps in texture units; the reference size keeps very wide or tall frames sane.
    let size = globals.size;
    let base = max(min(size.x, size.y), max(size.x, size.y) * 0.5);
    let reach = strength / 1000.0;
    let sigma = reach / 3.0;
    let dstep = reach / max(taps, 1e-5);
    let a = (-blur_angle(t) - 90.0) * 3.14159265 / 180.0;
    let stride = vec2f(dstep * cos(a) * base / size.x, -dstep * sin(a) * base / size.y);

    var centre = uv;
    if (dither > 1e-5) {
        centre += stride * dither * jitter(vec2f(uv.x, 1.0 - uv.y) * size * budget.y);
    }
    var acc = widened(uv, w);
    var total = 1.0;
    let count = min(i32(floor(taps)), 256);
    for (var n = 1; n <= count; n++) {
        let off = stride * f32(n);
        let d = length(off);
        let wt = exp(-0.5 * d * d / (sigma * sigma));
        let qa = centre - off;
        if (all(qa >= vec2f(0.0)) && all(qa <= vec2f(1.0))) { acc += widened(qa, w) * wt; total += wt; }
        let qb = centre + off;
        if (all(qb >= vec2f(0.0)) && all(qb <= vec2f(1.0))) { acc += widened(qb, w) * wt; total += wt; }
    }
    gpufx_write(id, clamp(acc / total, vec4f(0.0), vec4f(1.0)));
}
