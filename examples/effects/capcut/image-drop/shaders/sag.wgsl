// Image Drop, pass 1: pick the visible clip and bend it so its rows slide down toward the bottom edge.
//
// The frame is remapped vertically by a cubic curve whose two inner handles sit at
// 1/3 and `knee` of the height; pulling `knee` down squeezes the lower rows together
// and stretches the upper ones, so the picture seems to drop.

// The whole transition spans this many seconds of animation time.
const SPAN: f32 = 0.666667;
// Moment the second clip replaces the first.
const SWAP: f32 = 0.366667;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Height of the lower inner handle of the vertical curve over time.
fn knee(t: f32) -> f32 {
    if (t < 0.2) { return 0.666; }
    if (t < 0.333333) {
        let e = bezier_ease((t - 0.2) / 0.133333, vec4f(1.0, 0.0, 0.9999, 1.0));
        return mix(0.666, 0.375, e);
    }
    if (t < 0.366667) { return 0.375; }
    if (t < 0.433333) {
        let e = bezier_ease((t - 0.366667) / 0.066666, vec4f(0.166667, 0.166667, 0.833333, 0.833333));
        return mix(0.375, 0.666, e);
    }
    return 0.666;
}

// Vertical curve: source row v (0 = bottom) lands at this height.
fn bend(v: f32, k: f32) -> f32 {
    let inv = 1.0 - v;
    return 3.0 * inv * inv * v / 3.0 + 3.0 * inv * v * v * k + v * v * v;
}

fn bend_slope(v: f32, k: f32) -> f32 {
    let inv = 1.0 - v;
    return inv * inv + 6.0 * inv * v * (k - 1.0 / 3.0) + 3.0 * v * v * (1.0 - k);
}

// Source row that lands at height y.
fn unbend(y: f32, k: f32) -> f32 {
    var v = y;
    for (var i = 0; i < 10; i++) {
        let d = bend_slope(v, k);
        if (abs(d) < 1e-5) { break; }
        v = clamp(v - (bend(v, k) - y) / d, 0.0, 1.0);
    }
    return v;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    var q = uv;
    if (t >= 0.2 && t < 0.433333) {
        q.y = 1.0 - unbend(1.0 - uv.y, knee(t));
    }
    var c: vec4f;
    if (t < SWAP) {
        c = textureSampleLevel(first, smp, q, 0.0);
    } else {
        c = textureSampleLevel(second, smp, q, 0.0);
    }
    gpufx_write(id, vec4f(c.rgb, 1.0));
}
