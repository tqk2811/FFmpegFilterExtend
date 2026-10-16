// Wide Ripple, pass 1: the first clip swells and drifts right, then the second clip, swollen, settles in from the left.
//
// Output: the moving picture, premultiplied alpha (transparent where the shifted clip leaves a gap).
// Timeline of 2 s (progress 0..1 maps onto it); the cut to the second clip is at 1 s.

const SPAN: f32 = 2.0;
const COMP: f32 = 720.0; // the motion is laid out on a 720 px square

fn bez(a: f32, b: f32, c: f32, d: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return a * r * r * r + 3.0 * b * r * r * s + 3.0 * c * r * s * s + d * s * s * s;
}

// Timing curve through (0,0), (e.x,e.y), (e.z,e.w), (1,1): find the point at x = u, return its y.
fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 18; i++) {
        let mid = 0.5 * (lo + hi);
        if (bez(0.0, e.x, e.z, 1.0, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bez(0.0, e.y, e.w, 1.0, 0.5 * (lo + hi));
}

// Horizontal position (px on the 720 square): 360 -> 391.6 (0.733..1 s) -> 489 (1..1.233 s).
fn drift(t: f32) -> f32 {
    if (t < 0.733333) { return 360.0; }
    if (t < 1.0) { return mix(360.0, 391.592064, ease(vec4f(0.292289, 0.322498, 0.440817, 0.0), (t - 0.733333) / 0.266667)); }
    if (t < 1.233333) { return mix(391.592064, 489.0, ease(vec4f(0.221785, 0.112557, 0.538383, 1.0), (t - 1.0) / 0.233333)); }
    return 489.0;
}

// Size: 1 -> 1.2 -> 1 over the same keys.
fn swell(t: f32) -> f32 {
    if (t < 0.733333) { return 1.0; }
    if (t < 1.0) { return mix(1.0, 1.2, ease(vec4f(0.292289273, -0.167022441, 0.157413451, 0.946381851), (t - 0.733333) / 0.266667)); }
    if (t < 1.233333) { return mix(1.2, 1.0, ease(vec4f(0.221785204, -0.012349174, 0.538382597, 1.0), (t - 1.0) / 0.233333)); }
    return 1.0;
}

fn inside(q: vec2f) -> bool {
    return all(q >= vec2f(0.0)) && all(q <= vec2f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let s = swell(t);
    let x = drift(t) / COMP;
    var c = vec4f(0.0);
    if (t <= 1.0) {
        // first clip: centre at the drifting position
        let q = vec2f((uv.x - x) / s + 0.5, (uv.y - 0.5) / s + 0.5);
        if (inside(q)) { c = vec4f(textureSampleLevel(first, smp, q, 0.0).rgb, 1.0); }
    } else {
        // second clip: hangs 129 px left of the drifting point, so it lands centred at 489
        let q = vec2f((uv.x - x) / s + 489.0 / COMP, (uv.y - 0.5) / s + 0.5);
        if (inside(q)) { c = vec4f(textureSampleLevel(second, smp, q, 0.0).rgb, 1.0); }
    }
    gpufx_write(id, c);
}
