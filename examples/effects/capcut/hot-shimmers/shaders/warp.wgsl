// Hot Shimmers, pass 1: cross-fade the clips and push the result through a rolling heat-haze warp.
//
// `progress` 0..1 spans the scene time START..END (seconds). The second clip fades in
// linearly over FADE_IN..FADE_OUT; the warp strength swells, holds, then dies away while
// the two-octave gradient-noise field that drives it drifts upward.

const START: f32 = 0.466667;
const END: f32 = 1.433333;
const FADE_IN: f32 = 0.833333;
const FADE_OUT: f32 = 1.066667;
const HAZE_PEAK: f32 = 0.39;
const HAZE_DRIFT: f32 = 0.5;
const NOISE_ZOOM: f32 = 1.5;
const DETAIL_ZOOM: f32 = 1.7857143; // 100 / 56
const DETAIL_GAIN: f32 = 0.6;
const WARP_RANGE: f32 = 0.3;
const TAU: f32 = 6.2831853;

fn cubic(p1: f32, p2: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * p1 * r * r * s + 3.0 * p2 * r * s * s + s * s * s;
}

// y(x) of the bezier (0,0)-(k.x,k.y)-(k.z,k.w)-(1,1).
fn ease(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 14; n++) {
        let mid = (lo + hi) * 0.5;
        if (cubic(k.x, k.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return cubic(k.y, k.w, (lo + hi) * 0.5);
}

fn haze_amount(t: f32) -> f32 {
    if (t < 0.6) { return 0.0; }
    if (t < 0.866667) {
        return HAZE_PEAK * ease(vec4f(0.1666667, 0.2222222, 0.8333333, 0.9047619), (t - 0.6) / 0.266667);
    }
    if (t < 1.0) { return HAZE_PEAK; }
    if (t < 1.266667) {
        return HAZE_PEAK * (1.0 - ease(vec4f(0.1666667, 0.0952381, 0.8333333, 0.7777778), (t - 1.0) / 0.266667));
    }
    return 0.0;
}

// Single random number per lattice cell.
fn cell_hash(c: vec2f) -> f32 {
    var f = fract(c * 1324.5179);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y);
}

// Random pair for a lattice cell at animation key `key`.
fn cell_pair(c: vec2f, key: f32, seed: f32, base: f32) -> vec2f {
    var q = fract(c * (34.532 + key * 2.0 + seed * 0.8031));
    q += dot(q, q.yx + 15.434);
    let s = q.yx;
    return fract((q + s + 0.523) * s + base);
}

// Gradient vector of a lattice cell (direction and length slowly animated by `evo`).
fn cell_gradient(c: vec2f, evo: f32, seed: f32) -> vec2f {
    let base = cell_hash(c);
    let a = evo * 0.25 + base;
    let a0 = floor(a % 300.0);
    let a1 = floor((a + 1.0) % 300.0);
    let angle = mix(cell_pair(c, a0, seed, base).y, cell_pair(c, a1, seed, base).y + 1.0, fract(a)) * TAU;
    let b = evo * 2.0 + base;
    let b0 = floor(b % 300.0);
    let b1 = floor((b + 1.0) % 300.0);
    let len = mix(0.75, 1.0, mix(cell_pair(c, b0, seed, base).x, cell_pair(c, b1, seed, base).x, fract(b)));
    return vec2f(cos(angle), sin(angle)) * len;
}

fn gradient_noise(p: vec2f, density: vec2f, seed: f32) -> f32 {
    let g = p * density;
    let i = floor(g);
    let f = g - i;
    let s = smoothstep(vec2f(0.0), vec2f(1.0), f);
    let n00 = dot(cell_gradient(i, 0.0, seed), f);
    let n10 = dot(cell_gradient(i + vec2f(1.0, 0.0), 0.0, seed), f - vec2f(1.0, 0.0));
    let n01 = dot(cell_gradient(i + vec2f(0.0, 1.0), 0.0, seed), f - vec2f(0.0, 1.0));
    let n11 = dot(cell_gradient(i + vec2f(1.0, 1.0), 0.0, seed), f - vec2f(1.0, 1.0));
    return mix(mix(n00, n10, s.x), mix(n01, n11, s.x), s.y) * 0.5 + 0.5;
}

fn layered_noise(p: vec2f, density: vec2f, seed: f32) -> f32 {
    let coarse = gradient_noise(p, density, 1.0 + seed);
    let fine = gradient_noise(p * DETAIL_ZOOM, density, 1.0 + seed);
    return clamp((coarse + fine * DETAIL_GAIN) / (1.0 + DETAIL_GAIN), 0.0, 1.0);
}

fn fold(v: vec2f) -> vec2f {
    return abs(((v - 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = START + clamp(params.progress, 0.0, 1.0) * (END - START);
    let dims = globals.size;
    let short_side = min(dims.x, dims.y);

    var q = uv;
    let amount = haze_amount(t);
    if (amount > 0.0) {
        // The noise field lives in a bottom-up frame: y = 0 is the bottom edge.
        let nuv = vec2f(uv.x, 1.0 - uv.y);
        let drift = vec2f(0.0, HAZE_DRIFT * clamp((t - 0.6) / 0.666667, 0.0, 1.0));
        let p = (nuv - drift) / NOISE_ZOOM - 10.0;
        let density = vec2f(7.2) * dims / short_side;
        let nx = layered_noise(p, density, 2.11);
        let ny = layered_noise(p, density, 9.71);
        var shift = (vec2f(nx, ny) - 0.5) * amount * 10.0 * WARP_RANGE * short_side / dims;
        shift.y = -shift.y;
        q = fold(uv + shift);
    }

    let mixv = clamp((t - FADE_IN) / (FADE_OUT - FADE_IN), 0.0, 1.0);
    let a = textureSampleLevel(first, smp, q, 0.0);
    let b = textureSampleLevel(second, smp, q, 0.0);
    gpufx_write(id, vec4f(mix(a.rgb, b.rgb, mixv), 1.0));
}
