// Break swipe: the second clip is typed in over the first in five snaking horizontal strips, each strip smeared by a pulsing horizontal blur.

// The animation lives on a 2 s timeline (25 steps per second) that `progress` sweeps.
const TIMELINE: f32 = 2.0;
const STEP_RATE: f32 = 25.0;
// The steps land a little late against the 25-per-second grid.
const SHIFT: f32 = -0.4;

// Strip edges, as fractions of the height (top to bottom).
const EDGES = array<f32, 6>(0.0, 0.1953, 0.3965, 0.5977, 0.7969, 1.0);

// Per step: how far the current strip has been filled, in 1/512 of the width (0 = not started).
const FILL = array<f32, 26>(
    0.0, 113.0, 169.0, 302.0, 462.0,
    0.0, 0.0, 50.0, 178.0, 329.0, 457.0,
    0.0, 43.0, 188.0, 361.0, 506.0,
    0.0, 50.0, 178.0, 329.0, 457.0,
    0.0, 28.0, 161.0, 321.0, 454.0);
// Per step: number of strips already full.
const DONE = array<u32, 26>(
    0u, 0u, 0u, 0u, 0u,
    1u, 1u, 1u, 1u, 1u, 1u,
    2u, 2u, 2u, 2u, 2u,
    3u, 3u, 3u, 3u, 3u,
    4u, 4u, 4u, 4u, 4u);

fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

// CSS-like cubic-bezier easing, solved for x by bisection.
fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(e.x, e.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(e.y, e.w, 0.5 * (lo + hi));
}

fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, e: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(e, (t - t0) / (t1 - t0)));
}

// Blur radius in taps: a pulse for every strip, fading out once the last one lands.
fn smear(t: f32) -> f32 {
    let a = vec4f(0.1666667, 0.0, 0.8333333, 1.0);
    var v = 0.0;
    v = key(v, t, 0.0, 0.04, 0.0, 8.0, vec4f(0.3333333, 0.0, 0.8333333, 1.0));
    v = key(v, t, 0.04, 0.12, 8.0, 12.0, vec4f(0.156864, 0.0, 0.668059, 1.0));
    v = key(v, t, 0.12, 0.2, 12.0, 7.549767, vec4f(0.379862, 0.0, 0.720599, 0.236999));
    v = key(v, t, 0.2, 0.24, 7.549767, 0.0, vec4f(0.40252, 0.32397, 0.741388, 1.0));
    v = key(v, t, 0.24, 0.28, 0.0, 2.0, a);
    v = key(v, t, 0.28, 0.32, 2.0, 12.0, a);
    v = key(v, t, 0.32, 0.4, 12.0, 7.623786, vec4f(0.158829, 0.0, 0.620377, 0.192749));
    v = key(v, t, 0.4, 0.44, 7.623786, 0.0, vec4f(0.435823, 0.26599, 0.817658, 1.0));
    v = key(v, t, 0.44, 0.48, 0.0, 8.0, a);
    v = key(v, t, 0.48, 0.56, 8.0, 12.0, vec4f(0.156864, 0.0, 0.668059, 1.0));
    v = key(v, t, 0.56, 0.6, 12.0, 7.549767, vec4f(0.379862, 0.0, 0.720599, 0.6185));
    v = key(v, t, 0.6, 0.64, 7.549767, 0.0, vec4f(0.40252, 0.32397, 0.741388, 1.0));
    v = key(v, t, 0.64, 0.68, 0.0, 7.0, a);
    v = key(v, t, 0.68, 0.76, 7.0, 12.0, vec4f(0.158829, 0.0, 0.620377, 1.706541));
    v = key(v, t, 0.76, 0.8, 12.0, 8.848936, vec4f(0.358319, 0.5291, 0.698391, 0.314683));
    v = key(v, t, 0.8, 0.84, 8.848936, 0.0, vec4f(0.432085, 0.349609, 0.785231, 1.0));
    v = key(v, t, 0.84, 0.88, 0.0, 4.0, a);
    v = key(v, t, 0.88, 0.96, 4.0, 12.0, a);
    v = key(v, t, 0.96, 1.0, 12.0, 8.0, a);
    v = key(v, t, 1.0, 1.08, 8.0, 0.0, a);
    return v;
}

// Strips filled so far at step `s` (whole part = full strips, fraction = the current one); the strips jump step by step.
fn coverage(s: f32) -> f32 {
    let a = u32(clamp(floor(s), 0.0, 26.0));
    if (a >= 26u) { return 5.0; }
    return f32(DONE[a]) + FILL[a] / 512.0;
}

// 1 where the second clip is uncovered. Even strips fill from the left, odd ones from the right.
fn uncovered(uv: vec2f, cover: f32) -> f32 {
    var strip = 0u;
    for (var i = 1u; i < 5u; i++) {
        if (uv.y >= EDGES[i]) { strip = i; }
    }
    let done = floor(cover);
    if (f32(strip) < done) { return 1.0; }
    if (f32(strip) > done) { return 0.0; }
    let reach = cover - done;
    var x = uv.x;
    if ((strip & 1u) == 1u) { x = 1.0 - uv.x; }
    return select(0.0, 1.0, x < reach);
}

fn scene(uv: vec2f, cover: f32) -> vec4f {
    if (uncovered(uv, cover) > 0.5) { return textureSampleLevel(second, smp, uv, 0.0); }
    return textureSampleLevel(first, smp, uv, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;
    let cover = coverage(t * STEP_RATE + SHIFT);
    let here = scene(uv, cover);
    // The blur only touches the part already showing the second clip.
    let taps = floor(smear(t));
    if (taps < 1.0 || uncovered(uv, cover) < 0.5) { gpufx_write(id, vec4f(here.rgb, 1.0)); return; }
    let base = max(min(globals.size.x, globals.size.y), max(globals.size.x, globals.size.y) * 0.5);
    let dx = base / globals.size.x / 1000.0;
    var acc = here;
    var count = 1.0;
    for (var k = 1.0; k <= 12.0; k += 1.0) {
        if (k > taps) { break; }
        let l = uv.x - k * dx;
        if (l >= 0.0) { acc += scene(vec2f(l, uv.y), cover); count += 1.0; }
        let r = uv.x + k * dx;
        if (r <= 1.0) { acc += scene(vec2f(r, uv.y), cover); count += 1.0; }
    }
    gpufx_write(id, vec4f(acc.rgb / count, 1.0));
}
