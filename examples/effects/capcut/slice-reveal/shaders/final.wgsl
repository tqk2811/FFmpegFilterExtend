// Slice reveal, step 4: vertical shadow blur, then the right half and the left half are laid over the second clip.

const TIMELINE: f32 = 2.0;
const REACH: f32 = 50.0;
const SIGMA: f32 = 20.0;
const MAX_TAPS: f32 = 64.0;
// Shadow offset (reference pixels) and directions: down-right of the left half, up-left of the right half.
const OFFSET: f32 = 5.0;
const LEFT_ANGLE: f32 = -45.0;
const RIGHT_ANGLE: f32 = 135.0;

fn soft(q: vec2f) -> vec2f {
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return vec2f(0.0); }
    return textureSampleLevel(shade_x, smp, q, 0.0).rg;
}

fn shade(q: vec2f, step_uv: f32, taps: f32, step_px: f32, sigma: f32) -> vec2f {
    var acc = soft(q);
    var total = 1.0;
    for (var k = 1.0; k <= MAX_TAPS; k += 1.0) {
        if (k > taps) { break; }
        let d = k * step_px;
        let w = exp(-0.5 * d * d / (sigma * sigma));
        let o = vec2f(0.0, k * step_uv);
        acc += (soft(q + o) + soft(q - o)) * w;
        total += 2.0 * w;
    }
    return acc / total;
}

fn nudge(angle: f32) -> vec2f {
    let a = radians(angle);
    let size = globals.size;
    let span = min(size.x, size.y);
    // Offset scaled to the frame, then measured against the 1080-line reference width.
    return vec2f(cos(a), -sin(a)) * OFFSET * (span / 1080.0) / size;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;
    let px = min(globals.size.x, globals.size.y) / 1080.0;
    let reach = REACH * px;
    let sigma = SIGMA * px;
    let taps = min(floor(reach), MAX_TAPS);
    let step_px = reach / max(taps, 1.0);
    let step_uv = step_px / globals.size.y;

    // The left half's shadow fades in over the first 1/6 s; the right one is there from the start.
    let left_strength = clamp(t / 0.166667, 0.0, 1.0);
    let sl = shade(uv + nudge(LEFT_ANGLE), step_uv, taps, step_px, sigma).x * left_strength;
    let sr = shade(uv + nudge(RIGHT_ANGLE), step_uv, taps, step_px, sigma).y;

    var c = textureSampleLevel(second, smp, uv, 0.0).rgb;
    let r = textureSampleLevel(right, smp, uv, 0.0);
    let ra = r.a + sr * (1.0 - r.a);
    c = r.rgb + c * (1.0 - ra);
    let l = textureSampleLevel(left, smp, uv, 0.0);
    let la = l.a + sl * (1.0 - l.a);
    c = l.rgb + c * (1.0 - la);
    gpufx_write(id, vec4f(c, 1.0));
}
