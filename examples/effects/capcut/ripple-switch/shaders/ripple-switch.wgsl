// The second clip drops in from the top, oversized and vertically smeared, then shrinks into place while horizontal ripples shake it.
//
// `progress` 0..1 spans the scene time T_START..T_END (seconds). The second clip is a card
// above the first one; a vertical gaussian blur and a line-by-line horizontal displacement
// (gradient noise along y) are applied to the whole picture while they are active.

const T_START: f32 = 0.4337671;
const T_END: f32 = 1.4347581;
// The second clip exists from this time on.
const T_SHOW: f32 = 0.8008008;
// Window in which the blur / displacement run at all.
const FX_FROM: f32 = 0.7007007;
const FX_TO: f32 = 1.1678345;
const TAU: f32 = 6.2831853;

fn cubic(p1: f32, p2: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * p1 * r * r * s + 3.0 * p2 * r * s * s + s * s * s;
}

// y(x) of the timing curve (0,0)-(k.x,k.y)-(k.z,k.w)-(1,1).
fn ease(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 16; n++) {
        let mid = (lo + hi) * 0.5;
        if (cubic(k.x, k.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return cubic(k.y, k.w, (lo + hi) * 0.5);
}

fn segment(t: f32, t0: f32, t1: f32, v0: f32, v1: f32, k: vec4f) -> f32 {
    return mix(v0, v1, ease(k, clamp((t - t0) / (t1 - t0), 0.0, 1.0)));
}

// Vertical offset of the card in 1024-pixel units (negative = above).
fn drop_offset(t: f32) -> f32 {
    return segment(t, 0.800801, 1.034368, -1206.0, 0.0, vec4f(0.3333333, 0.0, 0.6666667, 1.0));
}

// Card scale (the same curve drives both axes).
fn card_scale(t: f32) -> f32 {
    return segment(t, 1.001001, 1.101101, 1.3, 1.0, vec4f(0.0999, 0.0, 0.0, 1.0));
}

fn blur_strength(t: f32) -> f32 {
    if (t < 0.800801) { return segment(t, 0.767434, 0.800801, 0.0, 190.0, vec4f(1.0, 0.0, 0.6666667, 1.0)); }
    return segment(t, 0.800801, 1.067734, 190.0, 0.0, vec4f(1.0, 0.0, 0.9667, 1.0));
}

fn ripple_strength(t: f32) -> f32 {
    if (t < 0.967634) { return segment(t, 0.934268, 0.967634, 0.0, 1.0, vec4f(0.3333333, 0.0, 0.6666667, 1.0)); }
    return segment(t, 0.967634, 1.167835, 1.0, 0.0, vec4f(0.3333333, 0.0, 0.6666667, 1.0));
}

// The layered picture before any filtering: card over the first clip.
fn scene(uv: vec2f, t: f32) -> vec3f {
    if (t >= T_SHOW) {
        // The card hangs from a parent that is scaled around the top edge, so the
        // scale is applied twice and also pulls the card down a little.
        let s = card_scale(t);
        let lift = 1.0 - 2.0 * drop_offset(t) / 1024.0 - s;
        let k = s * s;
        let q = vec2f(0.5 + (uv.x - 0.5) / k, 0.5 + (uv.y - 0.5 + 0.5 * lift) / k);
        if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
            return textureSampleLevel(second, smp, q, 0.0).rgb;
        }
    }
    return textureSampleLevel(first, smp, uv, 0.0).rgb;
}

// Taps per side of the vertical blur for a strength in 0..1000.
fn blur_taps(strength: f32) -> f32 {
    var scale = 0.8;
    var bias = 0.0;
    var gain = 1.0;
    if (strength > 500.0) { scale = 0.125; bias = 100.0; gain = 0.8; }
    else if (strength > 200.0) { scale = 0.25; bias = 60.0; gain = 0.7; }
    else if (strength > 50.0) { scale = 0.5; bias = 10.0; gain = 0.66; }
    else if (strength > 10.0) { scale = 0.7; bias = 2.0; gain = 0.78; }
    var n = (scale * strength + bias) * gain;
    if (n < 2.0) { n = floor(n + 0.5); }
    // Low quality setting thins the taps out.
    return n * 0.15848932;
}

fn blurred(uv: vec2f, t: f32) -> vec3f {
    let strength = clamp(blur_strength(t), 0.0, 1000.0);
    let taps = blur_taps(strength);
    if (taps < 1e-5) { return scene(uv, t); }
    let dims = globals.size;
    let base = max(min(dims.x, dims.y), max(dims.x, dims.y) * 0.5);
    let reach = strength / 1000.0;
    let sigma = reach / 3.0;
    let step = vec2f(0.0, reach / taps * base / dims.y);
    var acc = scene(uv, t);
    var total = 1.0;
    for (var i = 1.0; i <= taps; i += 1.0) {
        let off = step * i;
        let d = length(off);
        let w = exp(-0.5 * d * d / (sigma * sigma));
        // Taps that fall off the frame are dropped.
        let a = uv - off;
        if (a.y >= 0.0) { acc += scene(a, t) * w; total += w; }
        let b = uv + off;
        if (b.y <= 1.0) { acc += scene(b, t) * w; total += w; }
    }
    return clamp(acc / total, vec3f(0.0), vec3f(1.0));
}

// Random number per lattice cell.
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

// Gradient vector of a lattice cell (frozen animation).
fn cell_gradient(c: vec2f, seed: f32) -> vec2f {
    let base = cell_hash(c);
    let k0 = floor(base % 300.0);
    let k1 = floor((base + 1.0) % 300.0);
    let p0 = cell_pair(c, k0, seed, base);
    let p1 = cell_pair(c, k1, seed, base);
    let angle = mix(p0.y, p1.y + 1.0, fract(base)) * TAU;
    let len = mix(0.75, 1.0, mix(p0.x, p1.x, fract(base)));
    return vec2f(cos(angle), sin(angle)) * len;
}

fn gradient_noise(p: vec2f, density: vec2f, seed: f32) -> f32 {
    let g = p * density;
    let i = floor(g);
    let f = g - i;
    let s = smoothstep(vec2f(0.0), vec2f(1.0), f);
    let n00 = dot(cell_gradient(i, seed), f);
    let n10 = dot(cell_gradient(i + vec2f(1.0, 0.0), seed), f - vec2f(1.0, 0.0));
    let n01 = dot(cell_gradient(i + vec2f(0.0, 1.0), seed), f - vec2f(0.0, 1.0));
    let n11 = dot(cell_gradient(i + vec2f(1.0, 1.0), seed), f - vec2f(1.0, 1.0));
    return clamp(mix(mix(n00, n10, s.x), mix(n01, n11, s.x), s.y) * 0.5 + 0.5, 0.0, 1.0);
}

// Noise for row `y` (0 = bottom edge), evaluated on a quarter-resolution grid and filtered linearly.
fn row_noise(y: f32, dims: vec2f) -> f32 {
    let rows = max(floor(dims.y * 0.25), 1.0);
    let fy = y * rows - 0.5;
    let r0 = clamp(floor(fy), 0.0, rows - 1.0);
    let r1 = clamp(floor(fy) + 1.0, 0.0, rows - 1.0);
    let density = vec2f(7.2) * dims / min(dims.x, dims.y);
    let n0 = gradient_noise(vec2f(0.5, ((r0 + 0.5) / rows) * 10.0 - 10.0), density, 3.11);
    let n1 = gradient_noise(vec2f(0.5, ((r1 + 0.5) / rows) * 10.0 - 10.0), density, 3.11);
    return mix(n0, n1, clamp(fy - floor(fy), 0.0, 1.0));
}

fn fold(v: vec2f) -> vec2f {
    return abs(((v - 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = T_START + params.progress * (T_END - T_START);
    if (t < FX_FROM || t >= FX_TO) {
        gpufx_write(id, vec4f(scene(uv, t), 1.0));
        return;
    }
    let dims = globals.size;
    var q = uv;
    let amount = ripple_strength(t);
    if (amount > 0.0) {
        // Every row is pushed sideways by the noise value of that row.
        let n = (row_noise(1.0 - uv.y, dims) - 0.5) * amount * 10.0;
        q = fold(vec2f(uv.x + n * min(dims.x, dims.y) / dims.x * 0.03, uv.y));
    }
    gpufx_write(id, vec4f(blurred(q, t), 1.0));
}
