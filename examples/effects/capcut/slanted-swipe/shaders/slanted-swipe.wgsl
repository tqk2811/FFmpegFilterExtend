// Hard cut hidden under a strong slanted motion blur, with fast black flicker before and after the cut and a split white flash on it.

// The animation is laid out on a 2-second timeline; progress 0..1 maps onto it.
const SPAN: f32 = 2.0;
// Moment of the cut from the first clip to the second.
const CUT_TIME: f32 = 1.0;
// Peak blur strength (on a 0..1000 scale) and the blur direction, in degrees from vertical.
const BLUR_PEAK: f32 = 150.0;
const BLUR_ANGLE: f32 = 19.0;
// Length of one fade step of the black flicker.
const FLICKER_STEP: f32 = 0.04;
// Length of each white half-flash in timeline seconds: one 30 fps frame (1/30 s) at the 0.8 s default length.
const FLASH_SPAN: f32 = 0.0833333;
// Split line of the two white half-frame flashes (fraction of the width).
const LEFT_FLASH_EDGE: f32 = 0.4972;
const RIGHT_FLASH_EDGE: f32 = 0.4944;
const MAX_TAPS: i32 = 160;

// Blur strength over time: ramps up, holds, ramps down (linear keys).
fn blur_strength(t: f32) -> f32 {
    if (t <= 0.84 || t >= 1.16) { return 0.0; }
    if (t < 0.92) { return BLUR_PEAK * (t - 0.84) / 0.08; }
    if (t <= 1.08) { return BLUR_PEAK; }
    return BLUR_PEAK * (1.16 - t) / 0.08;
}

// Black flicker starting at `start`: five linear steps full -> clear -> full ... -> clear.
fn flicker(t: f32, start: f32) -> f32 {
    let x = (t - start) / FLICKER_STEP;
    if (x < 0.0 || x > 5.0) { return 0.0; }
    let step = min(floor(x), 4.0);
    let f = x - step;
    if (step % 2.0 == 0.0) { return 1.0 - f; }
    return f;
}

fn source(uv: vec2f, use_second: bool) -> vec3f {
    if (use_second) { return textureSampleLevel(second, smp, uv, 0.0).rgb; }
    return textureSampleLevel(first, smp, uv, 0.0).rgb;
}

// Gaussian blur along one line in both directions; samples outside the frame are skipped.
// Tap count and spacing follow the strength tiers of the original blur.
fn line_blur(uv: vec2f, strength: f32, use_second: bool) -> vec3f {
    if (strength <= 0.0) { return source(uv, use_second); }
    var tier = 0.5;
    var bias = 10.0;
    var shrink = 0.66;
    if (strength <= 10.0) { tier = 0.8; bias = 0.0; shrink = 1.0; }
    else if (strength <= 50.0) { tier = 0.7; bias = 2.0; shrink = 0.78; }
    var taps = (tier * strength + bias) * shrink;
    if (taps < 2.0) { taps = floor(taps + 0.5); }
    if (taps < 1e-5) { return source(uv, use_second); }
    let reach = strength / 1000.0;
    let sigma = reach / 3.0;
    let stride = reach / taps;
    // Keep the streak length relative to the shorter side (long side counts at most half).
    let base = max(min(globals.size.x, globals.size.y), max(globals.size.x, globals.size.y) * 0.5);
    let axis_scale = base / globals.size;
    let a = radians(BLUR_ANGLE + 90.0);
    let dir = vec2f(-cos(a), -sin(a)) * axis_scale * stride;
    var sum = source(uv, use_second);
    var weight = 1.0;
    for (var k = 1; k <= MAX_TAPS; k++) {
        let kf = f32(k);
        if (kf > taps) { break; }
        let d = dir * kf;
        let l = stride * kf * length(vec2f(-cos(a), -sin(a)) * axis_scale);
        let w = exp(-0.5 * l * l / (sigma * sigma));
        let p0 = uv - d;
        if (all(p0 >= vec2f(0.0)) && all(p0 <= vec2f(1.0))) { sum += source(p0, use_second) * w; weight += w; }
        let p1 = uv + d;
        if (all(p1 >= vec2f(0.0)) && all(p1 <= vec2f(1.0))) { sum += source(p1, use_second) * w; weight += w; }
    }
    return sum / weight;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SPAN;
    var c = line_blur(uv, blur_strength(t), t > CUT_TIME);
    // White flash: left half just before the cut, right half just after it.
    if (t > CUT_TIME - FLASH_SPAN && t <= CUT_TIME && uv.x < LEFT_FLASH_EDGE) {
        c = mix(c, vec3f(1.0), (CUT_TIME - t) / FLASH_SPAN);
    }
    if (t > CUT_TIME && t < CUT_TIME + FLASH_SPAN && uv.x > RIGHT_FLASH_EDGE) {
        c = mix(c, vec3f(1.0), (CUT_TIME + FLASH_SPAN - t) / FLASH_SPAN);
    }
    c = mix(c, vec3f(0.0), flicker(t, 0.76));
    c = mix(c, vec3f(0.0), flicker(t, 1.04));
    gpufx_write(id, vec4f(c, 1.0));
}
