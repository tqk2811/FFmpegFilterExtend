// Whip Tear, pass 2: blur the torn halves horizontally for their soft drop shadow (gamma-2.2 weighted Gaussian).
//
// Radius 0.07 of the larger of (short side, long side / 2), sigma = radius / 2.5, about 30 taps a side.
// Taps that fall off the frame are left out of the sum.

const RADIUS: f32 = 0.07;
const TAPS: f32 = 29.7;
const GAMMA: f32 = 2.2;

fn tap(q: vec2f) -> vec4f {
    let c = textureSampleLevel(torn, smp, q, 0.0);
    return vec4f(pow(max(c.rgb, vec3f(0.0)), vec3f(GAMMA)), c.a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let base = max(min(globals.size.x, globals.size.y), max(globals.size.x, globals.size.y) * 0.5);
    let axis = vec2f(1.0, 0.0);
    let radius = RADIUS * dot(axis, vec2f(base) / globals.size);
    let sigma = radius / 2.5;
    let stride = radius / TAPS;
    var sum = tap(uv);
    var total = 1.0;
    for (var i = 1.0; i <= TAPS; i += 1.0) {
        let d = i * stride;
        let w = exp(-0.5 * d * d / (sigma * sigma));
        let lo = uv - axis * d;
        let hi = uv + axis * d;
        if (dot(lo, axis) >= 0.0) { sum += tap(lo) * w; total += w; }
        if (dot(hi, axis) <= 1.0) { sum += tap(hi) * w; total += w; }
    }
    let c = sum / total;
    gpufx_write(id, vec4f(pow(max(c.rgb, vec3f(0.0)), vec3f(1.0 / GAMMA)), c.a));
}
