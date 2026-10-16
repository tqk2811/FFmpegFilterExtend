// Dissolve into the second clip behind a horizontal blur that swells with an exposure flash.
//
// Timeline in seconds, `progress` 0..1 mapped onto 0..TIMELINE_END:
// - the first clip's opacity drops linearly from 1 to 0 by FADE_END,
// - the blur strength eases up to PEAK_STRENGTH at PEAK_TIME, then eases back to 0,
// - the exposure boost (0 -> 2 stops) and gamma (1 -> 4) follow the same rise and fall.

const PEAK_TIME: f32 = 0.233333;
const TIMELINE_END: f32 = 0.5;
const FADE_END: f32 = 0.4;
const PEAK_STRENGTH: f32 = 120.0;
const TAP_LIMIT: i32 = 128;
// Ease curve control points (x1, y1, x2, y2) shared by the blur rise and fall.
const BLUR_EASE: vec4f = vec4f(0.33333333, 0.0, 0.0, 1.0);

// One coordinate of a cubic bezier whose ends sit at 0 and `last`.
fn cubic(p1: f32, p2: f32, last: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * p1 * r * r * s + 3.0 * p2 * r * s * s + last * s * s * s;
}

// Treat the bezier (0,0)-(k.x,k.y)-(k.z,k.w)-(1,1) as a function y(x): find the curve
// parameter for x by bisection, then return y there.
fn ease(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 12; n++) {
        let mid = (lo + hi) * 0.5;
        if (cubic(k.x, k.z, 1.0, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return cubic(k.y, k.w, 1.0, (lo + hi) * 0.5);
}

// The two clips layered: the first on top with the given opacity.
fn layered(q: vec2f, top_opacity: f32) -> vec4f {
    let over = textureSampleLevel(first, smp, q, 0.0);
    let under = textureSampleLevel(second, smp, q, 0.0);
    return mix(under, over, top_opacity);
}

// The blur runs on a reduced copy of the layered clips (`grid` texels, see
// `shrink_for`). Rebuild that copy on the fly: each reduced texel is one filtered read
// of the full-size image at its centre, and the blur reads the copy bilinearly. This
// is what softens the picture slightly even when the blur strength is close to zero.
fn reduced(q: vec2f, top_opacity: f32, grid: vec2f) -> vec4f {
    let pos = q * grid - 0.5;
    let base = floor(pos);
    let f = pos - base;
    let last = grid - 1.0;
    let i0 = clamp(base, vec2f(0.0), last);
    let i1 = clamp(base + 1.0, vec2f(0.0), last);
    let c00 = layered((vec2f(i0.x, i0.y) + 0.5) / grid, top_opacity);
    let c10 = layered((vec2f(i1.x, i0.y) + 0.5) / grid, top_opacity);
    let c01 = layered((vec2f(i0.x, i1.y) + 0.5) / grid, top_opacity);
    let c11 = layered((vec2f(i1.x, i1.y) + 0.5) / grid, top_opacity);
    return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

// Size factor of the reduced copy, following the same strength bands as `taps_for`.
fn shrink_for(strength: f32) -> f32 {
    if (strength <= 10.0) { return 0.8; }
    if (strength <= 50.0) { return 0.7; }
    if (strength <= 200.0) { return 0.5; }
    return 0.25;
}

// Number of taps on each side for a given blur strength: a piecewise-linear table that
// grows slower for stronger blurs. Counts below 2 are rounded to whole taps.
fn taps_for(strength: f32) -> f32 {
    var n: f32;
    if (strength <= 10.0) {
        n = 0.8 * strength;
    } else if (strength <= 50.0) {
        n = (0.7 * strength + 2.0) * 0.78;
    } else if (strength <= 200.0) {
        n = (0.5 * strength + 10.0) * 0.66;
    } else {
        n = (0.25 * strength + 60.0) * 0.7;
    }
    if (n < 2.0) { n = floor(n + 0.5); }
    return n;
}

// Exposure in roughly linear light (gamma 2.2): scale by 2^stops, apply the extra gamma,
// then go back to display values.
fn expose(v: f32, stops: f32, gamma: f32) -> f32 {
    let lin = pow(max(v, 0.0), 2.2) * exp2(stops);
    return pow(pow(lin, 1.0 / gamma), 1.0 / 2.2);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let time = clamp(params.progress, 0.0, 1.0) * TIMELINE_END;

    let top_opacity = 1.0 - clamp(time / FADE_END, 0.0, 1.0);
    // `flash` is 0 at both ends of the timeline and 1 at the peak.
    var strength: f32;
    var flash: f32;
    if (time < PEAK_TIME) {
        flash = time / PEAK_TIME;
        strength = PEAK_STRENGTH * ease(BLUR_EASE, flash);
    } else {
        let fall = clamp((time - PEAK_TIME) / (TIMELINE_END - PEAK_TIME), 0.0, 1.0);
        strength = PEAK_STRENGTH - PEAK_STRENGTH * ease(BLUR_EASE, fall);
        flash = 1.0 - fall;
    }
    let stops = 2.0 * flash;
    let gamma = 1.0 + 3.0 * flash;

    // Blur radius is in units of a reference side (the shorter side, or half the longer
    // one if that is bigger), converted to uv along x. Gaussian sigma = radius / 3.
    let dims = globals.size;
    let reference = max(min(dims.x, dims.y), max(dims.x, dims.y) * 0.5);
    let to_uv_x = reference / dims.x;
    let radius = strength / 1000.0;
    let sigma = max(radius / 3.0, 1e-6);
    let taps = min(taps_for(strength), f32(TAP_LIMIT));

    let grid = floor(dims * shrink_for(strength));
    var color: vec4f;
    if (taps < 1e-5) {
        color = reduced(uv, top_opacity, grid);
    } else {
        let step_x = vec2f(radius / taps * to_uv_x, 0.0);
        var total = reduced(uv, top_opacity, grid);
        var weights = 1.0;
        for (var n = 1; n <= TAP_LIMIT; n++) {
            let tap = f32(n);
            if (tap > taps) { break; }
            let offset = step_x * tap;
            let d = length(offset);
            let w = exp(-0.5 * d * d / (sigma * sigma));
            // Taps that fall outside the frame are dropped, not clamped.
            let left = uv - offset;
            if (left.x >= 0.0 && left.x <= 1.0) {
                total += reduced(left, top_opacity, grid) * w;
                weights += w;
            }
            let right = uv + offset;
            if (right.x >= 0.0 && right.x <= 1.0) {
                total += reduced(right, top_opacity, grid) * w;
                weights += w;
            }
        }
        color = clamp(total / weights, vec4f(0.0), vec4f(1.0));
    }

    let rgb = vec3f(
        expose(color.r, stops, gamma),
        expose(color.g, stops, gamma),
        expose(color.b, stops, gamma));
    gpufx_write(id, vec4f(clamp(rgb, vec3f(0.0), vec3f(1.0)), 1.0));
}
