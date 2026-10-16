// Slice reveal, step 3: horizontal gaussian of both halves' coverage, the first half of the shadow blur.

// Blur radius and sigma in pixels of a 1080-line reference frame.
const REACH: f32 = 50.0;
const SIGMA: f32 = 20.0;
const MAX_TAPS: f32 = 64.0;

fn coverage(q: vec2f) -> vec2f {
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return vec2f(0.0); }
    return vec2f(textureSampleLevel(left, smp, q, 0.0).a, textureSampleLevel(right, smp, q, 0.0).a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let px = min(globals.size.x, globals.size.y) / 1080.0;
    let reach = REACH * px;
    let sigma = SIGMA * px;
    let taps = min(floor(reach), MAX_TAPS);
    let step = reach / max(taps, 1.0);
    var acc = coverage(uv);
    var total = 1.0;
    for (var k = 1.0; k <= MAX_TAPS; k += 1.0) {
        if (k > taps) { break; }
        let d = k * step;
        let w = exp(-0.5 * d * d / (sigma * sigma));
        let o = vec2f(d / globals.size.x, 0.0);
        acc += (coverage(uv + o) + coverage(uv - o)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(acc / total, 0.0, 1.0));
}
