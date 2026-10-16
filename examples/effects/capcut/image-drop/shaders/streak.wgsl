// Image Drop, pass 2: smear the bent picture with a vertical Gaussian motion blur that peaks at the cut.

const SPAN: f32 = 0.666667;
// Blur strength is in thousandths of the frame's base size; the Gaussian spans three sigmas.
const STRENGTH_UNIT: f32 = 1000.0;
const SIGMAS: f32 = 3.0;
const MAX_TAPS: i32 = 256;

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

fn strength(t: f32) -> f32 {
    if (t < 0.2) { return 0.0; }
    if (t < 0.333333) {
        return 36.0 * bezier_ease((t - 0.2) / 0.133333, vec4f(1.0, 0.0, 0.944444, 1.001374));
    }
    if (t < 0.366667) { return 36.0; }
    if (t < 0.433333) {
        return 36.0 * (1.0 - bezier_ease((t - 0.366667) / 0.066666, vec4f(0.333333, 0.0, 0.422223, 0.992856)));
    }
    return 0.0;
}

// Tap count for a given strength (fewer taps per unit as the blur grows).
fn tap_count(s: f32) -> f32 {
    var n: f32;
    if (s <= 10.0) { n = 0.8 * s; }
    else if (s <= 50.0) { n = (0.7 * s + 2.0) * 0.78; }
    else { n = (0.5 * s + 10.0) * 0.66; }
    if (n < 2.0) { n = floor(n + 0.5); }
    return n;
}

fn inside(p: vec2f) -> bool {
    return p.x >= 0.0 && p.y >= 0.0 && p.x <= 1.0 && p.y <= 1.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let s = strength(t);
    let taps = tap_count(s);
    let centre = textureSampleLevel(sagged, smp, uv, 0.0).rgb;
    if (taps < 1e-5) { gpufx_write(id, vec4f(centre, 1.0)); return; }

    let base = max(min(globals.size.x, globals.size.y), max(globals.size.x, globals.size.y) * 0.5);
    let reach = s / STRENGTH_UNIT;
    let sigma = reach / SIGMAS;
    let step = vec2f(0.0, reach / taps * base / globals.size.y);
    var acc = centre;
    var total = 1.0;
    for (var i = 1; i <= MAX_TAPS; i++) {
        let k = f32(i);
        if (k > taps) { break; }
        let off = step * k;
        let d = length(off);
        let w = exp(-0.5 * d * d / (sigma * sigma));
        let a = uv - off;
        if (inside(a)) { acc += textureSampleLevel(sagged, smp, a, 0.0).rgb * w; total += w; }
        let b = uv + off;
        if (inside(b)) { acc += textureSampleLevel(sagged, smp, b, 0.0).rgb * w; total += w; }
    }
    gpufx_write(id, vec4f(acc / total, 1.0));
}
