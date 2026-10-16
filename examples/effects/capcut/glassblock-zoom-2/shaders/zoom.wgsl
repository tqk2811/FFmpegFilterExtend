// Glassblock Zoom 2, pass 2: scale pulse about the centre, smeared into a zoom blur, with mirrored edges.
//
// The scale bumps to 1.05, then swells to 5x at 1 s and back. The blur traces the scale over a
// short window around the current time (from three quarters of a frame back to one and three
// quarters ahead, extrapolated from the scale one frame earlier) and takes 12 to 24 taps
// depending on how far the trace moves, jittered per pixel.

const FRAME: f32 = 0.033333;
const TAPS_MIN: f32 = 12.0;
const TAPS_MAX: f32 = 24.0;

fn cubic(p1: f32, p2: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * p1 * r * r * s + 3.0 * p2 * r * s * s + s * s * s;
}

fn ease(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 16; n++) {
        let mid = (lo + hi) * 0.5;
        if (cubic(k.x, k.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return cubic(k.y, k.w, (lo + hi) * 0.5);
}

fn span(t: f32, t0: f32, t1: f32, a: f32, b: f32, k: vec4f) -> f32 {
    return mix(a, b, ease(k, (t - t0) / (t1 - t0)));
}

fn scale_at(t: f32) -> f32 {
    let slow = vec4f(0.66, 0.0, 0.34, 1.0);
    if (t < 0.2) { return 1.0; }
    if (t < 0.366667) { return span(t, 0.2, 0.366667, 1.0, 1.05, vec4f(0.166667, 0.166667, 0.833333, 1.0)); }
    if (t < 0.5) { return span(t, 0.366667, 0.5, 1.05, 1.0, vec4f(0.166667, 0.0, 0.843041, 1.0)); }
    if (t < 1.0) { return span(t, 0.5, 1.0, 1.0, 5.0, slow); }
    if (t < 1.5) { return span(t, 1.0, 1.5, 5.0, 1.0, slow); }
    return 1.0;
}

fn jitter(a: f32, b: f32) -> f32 {
    var f = fract(vec2f(a, b) * 13.517);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y);
}

// Folds any coordinate back into 0..1 like a mirror.
fn fold(p: vec2f) -> vec2f {
    let q = p - 1.0;
    return abs(q - 2.0 * floor(q * 0.5) - 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = params.progress * 2.0;
    let now = scale_at(t);
    let before = scale_at(t - FRAME);
    if (now == 1.0 && before == 1.0) {
        gpufx_write(id, textureSampleLevel(fringed, smp, uv, 0.0));
        return;
    }
    var trace: array<vec2f, 6>;
    for (var i = 0; i < 6; i++) {
        let w = 0.75 + 0.2 * f32(i);
        let s = before * (1.0 - w) + now * w;
        trace[i] = (uv - 0.5) / s + 0.5;
    }
    let taps = floor(TAPS_MIN + (TAPS_MAX - TAPS_MIN) * smoothstep(0.0, 0.2, length(trace[5] - trace[0])));
    let gl_y = 1.0 - uv.y;
    var sum = vec4f(0.0);
    for (var k = 0.0; k < taps; k += 1.0) {
        let f = (k / (taps - 1.0) + (jitter(k + uv.x, k * gl_y) - 0.5) / taps) * 5.0;
        let seg = clamp(i32(floor(f)), 0, 4);
        let p = mix(trace[seg], trace[seg + 1], f - f32(seg));
        sum += textureSampleLevel(fringed, smp, fold(p), 0.0);
    }
    gpufx_write(id, sum / taps);
}
