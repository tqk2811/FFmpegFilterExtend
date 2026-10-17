// Transform Shimmer, pass 2: horizontal half of the swelling Gaussian blur, averaged in linear light.

const SPAN: f32 = 1.1666667;
const GAMMA: f32 = 2.2;
const MAX_TAPS: i32 = 64;

// Blur strength on a 0..1000 scale: up to 50 at 0.5 s, back to 0 at 1 s.
fn strength(t: f32) -> f32 {
    if (t < 0.5) { return 100.0 * t; }
    return max(50.0 * (1.0 - (t - 0.5) / 0.5), 0.0);
}

// Taps on each side of the centre for a given strength.
fn taps(s: f32) -> f32 {
    var n: f32;
    if (s <= 30.0) { n = (0.5 * s + 2.0) * 0.78; }
    else if (s <= 100.0) { n = (0.5 * s + 10.0) * 0.66; }
    else { n = (0.25 * s + 50.0) * 0.7; }
    if (n < 2.0) { n = floor(n + 0.5); }
    return n;
}

fn lin(q: vec2f) -> vec3f {
    return pow(textureSampleLevel(faded, smp, q, 0.0).rgb, vec3f(GAMMA));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let s = strength(clamp(params.progress, 0.0, 1.0) * SPAN);
    let n = taps(s);
    if (s <= 0.01 || n < 1e-5) {
        gpufx_write(id, vec4f(textureSampleLevel(faded, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    let base = max(min(globals.size.x, globals.size.y), max(globals.size.x, globals.size.y) * 0.5);
    let radius = base / globals.size.x * s / 1000.0;
    let sigma = radius / 2.5;
    let stride = radius / n;
    var sum = lin(uv);
    var total = 1.0;
    for (var i = 1; i <= MAX_TAPS; i++) {
        let k = f32(i);
        if (k > n) { break; }
        let d = k * stride;
        let w = exp(-0.5 * d * d / (sigma * sigma));
        // Taps past the frame edge are dropped, not clamped.
        if (uv.x - d >= 0.0) { sum += lin(vec2f(uv.x - d, uv.y)) * w; total += w; }
        if (uv.x + d <= 1.0) { sum += lin(vec2f(uv.x + d, uv.y)) * w; total += w; }
    }
    gpufx_write(id, vec4f(pow(sum / total, vec3f(1.0 / GAMMA)), 1.0));
}
