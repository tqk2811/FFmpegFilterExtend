// Rotational blur of the first clip around its centre, strength keyed over the start of the transition.

// Length of the animation timeline in seconds.
const SPAN: f32 = 1.0833333;

// Blur amount (200 = one full turn) at time t.
fn spin_amount(t: f32) -> f32 {
    if (t < 0.333333) { return mix(0.0, -9.0, clamp((t - 0.208333) / 0.125, 0.0, 1.0)); }
    return mix(-9.0, -5.0, clamp((t - 0.333333) / 0.208334, 0.0, 1.0));
}

// Per-pixel jitter in [0, 1).
fn grain(p: vec2f) -> f32 {
    let f = fract(p * 13.517);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

// Sample in bottom-up texture coordinates; outside the frame is transparent.
fn fetch(q: vec2f) -> vec4f {
    if (q.x < 0.0 || q.y < 0.0 || q.x > 1.0 || q.y > 1.0) { return vec4f(0.0); }
    return textureSampleLevel(first, smp, vec2f(q.x, 1.0 - q.y), 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let strength = spin_amount(t) / 200.0;
    let base = textureSampleLevel(first, smp, uv, 0.0);
    // The outgoing card has shrunk to nothing by then, so skip the work.
    if (strength == 0.0 || t >= 0.791667) { gpufx_write(id, base); return; }
    let q = vec2f(uv.x, 1.0 - uv.y);
    let centre = vec2f(0.5);
    let reach = length((q - centre) * strength);
    let taps = min(8.0 * 20.0 * (0.9 * reach + 0.1) + 5.0, 128.0);
    let step = 6.2831850 * strength / taps;
    let jitter = 0.5 * (grain(q) * 2.0 - 1.0) * step;
    let dims = vec2f(textureDimensions(first));
    let aspect = dims.x / dims.y;
    var acc = base;
    var total = 1.0;
    for (var k = 1; k <= 128; k++) {
        if (f32(k) > taps) { break; }
        let a = f32(k) * step + jitter;
        var d = q - centre;
        d.y /= aspect;
        d = vec2f(cos(a) * d.x - sin(a) * d.y, sin(a) * d.x + cos(a) * d.y);
        d.y *= aspect;
        acc += fetch(centre + d);
        total += 1.0;
    }
    gpufx_write(id, acc / total);
}
