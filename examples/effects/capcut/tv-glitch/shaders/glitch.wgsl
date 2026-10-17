// TV Glitch: hard cut hidden under a CRT lens bulge, banded static, jumping picture shifts, sliding row bands and RGB fringing.
//
// Scene clock t = progress (seconds of a 1 s scene). The cut to the second clip is at 0.4 s;
// the lens runs 0.16..0.8 s, the static 0.2..0.76 s, the shake, band warp and fringing 0.24..0.72 s.

const CUT: f32 = 0.4;
const NOISE_W: vec2f = vec2f(576.0, 512.0); // static sheet, scaled to cover the frame
const FRINGE: vec2f = vec2f(0.134, 0.178);

// Shake path: 11 hops of 0.04 s from 0.24 s. Each hop: timing curve (x1, y1, x2, y2),
// then start, end, start handle, end handle (frame fractions).
const HOP_EASE = array<vec4f, 11>(
    vec4f(0.166667, 0.166663, 0.833333, 0.472741), vec4f(0.166667, 0.098976, 0.833333, 0.829876),
    vec4f(0.166667, 0.163345, 0.833333, 0.885462), vec4f(0.166667, 0.305865, 0.833333, 0.756658),
    vec4f(0.166667, 0.126732, 0.833333, 0.863455), vec4f(0.166667, 0.213836, 0.833333, 0.814693),
    vec4f(0.166667, 0.151433, 0.833333, 0.874694), vec4f(0.166667, 0.24878, 0.833333, 0.686032),
    vec4f(0.166667, 0.113442, 0.833333, 0.834817), vec4f(0.166667, 0.168174, 0.833333, 0.862924),
    vec4f(0.166667, 0.212545, 0.833333, 0.833335));
const HOP_PTS = array<vec2f, 12>(
    vec2f(0.326433, 0.523522), vec2f(0.323418, 0.536315), vec2f(0.138629, 0.425984),
    vec2f(0.417058, 0.450571), vec2f(0.381841, 0.412391), vec2f(0.244693, 0.496556),
    vec2f(0.364448, 0.494080), vec2f(0.435415, 0.414223), vec2f(0.395978, 0.446710),
    vec2f(0.176915, 0.459547), vec2f(0.352200, 0.530543), vec2f(0.215997, 0.525785));
const HOP_OUT = array<vec2f, 11>(
    vec2f(0.325931, 0.525654), vec2f(0.292118, 0.520059), vec2f(0.154236, 0.411693),
    vec2f(0.457593, 0.448305), vec2f(0.353114, 0.420055), vec2f(0.241794, 0.510171),
    vec2f(0.396235, 0.480358), vec2f(0.440670, 0.406328), vec2f(0.352894, 0.454264),
    vec2f(0.169619, 0.473519), vec2f(0.358713, 0.541583));
const HOP_IN = array<vec2f, 11>(
    vec2f(0.354719, 0.552572), vec2f(0.123022, 0.440275), vec2f(0.376523, 0.452836),
    vec2f(0.410569, 0.404727), vec2f(0.247592, 0.482941), vec2f(0.332661, 0.507802),
    vec2f(0.430160, 0.422118), vec2f(0.439061, 0.439156), vec2f(0.184211, 0.445575),
    vec2f(0.345686, 0.519504), vec2f(0.238698, 0.526578));

fn bez(a: vec2f, b: vec2f, c: vec2f, d: vec2f, s: f32) -> vec2f {
    let u = 1.0 - s;
    return a * u * u * u + b * 3.0 * u * u * s + c * 3.0 * u * s * s + d * s * s * s;
}

// Timing curve: find the curve point whose x is `x`, return its y.
fn ease(e: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let m = 0.5 * (lo + hi);
        if (bez(vec2f(0.0), e.xy, e.zw, vec2f(1.0), m).x > x) { hi = m; } else { lo = m; }
    }
    return bez(vec2f(0.0), e.xy, e.zw, vec2f(1.0), 0.5 * (lo + hi)).y;
}

fn shake(t: f32) -> vec2f {
    let k = i32(floor((t - 0.24) / 0.04));
    if (k >= 11) { return HOP_PTS[11]; }
    let i = max(k, 0);
    let s = ease(HOP_EASE[i], clamp((t - 0.24 - f32(i) * 0.04) / 0.04, 0.0, 1.0));
    return along_path(i, s);
}

// Hops move at constant speed along the curve: the timing value is a fraction of the path length.
fn along_path(i: i32, s: f32) -> vec2f {
    var lens: array<f32, 33>;
    var prev = HOP_PTS[i];
    lens[0] = 0.0;
    for (var j = 1; j <= 32; j++) {
        let c = bez(HOP_PTS[i], HOP_OUT[i], HOP_IN[i], HOP_PTS[i + 1], f32(j) / 32.0);
        lens[j] = lens[j - 1] + length(c - prev);
        prev = c;
    }
    let goal = s * lens[32];
    var j = 1;
    while (j < 32 && lens[j] < goal) { j++; }
    let f = clamp((goal - lens[j - 1]) / max(lens[j] - lens[j - 1], 1e-6), 0.0, 1.0);
    return bez(HOP_PTS[i], HOP_OUT[i], HOP_IN[i], HOP_PTS[i + 1], (f32(j - 1) + f) / 32.0);
}

// Square-wave band warp: alternate 195 px rows slide sideways by WAVE_AMP px (1080 px reference),
// fading to nothing towards every frame edge.
const WAVE_AMP: f32 = 555.0;
const WAVE_LEN: f32 = 390.0;
const WAVE_SIGN: f32 = -1.0;
fn band_warp(uv: vec2f) -> vec2f {
    let unit = 1080.0 / min(globals.size.x, globals.size.y);
    let dim = globals.size * unit;
    let px = uv * dim;
    let on = step(fract(WAVE_SIGN * px.y / WAVE_LEN), 0.5);
    let ramp = WAVE_AMP * 1.2;
    let edge = min(clamp(px / ramp, vec2f(0.0), vec2f(1.0)), clamp((dim - px) / ramp, vec2f(0.0), vec2f(1.0)));
    let moved = px - vec2f(on * WAVE_AMP, 0.0) * min(edge.x, edge.y);
    return moved / dim;
}

// Shifted picture with the band warp on top; outside the frame reads black.
fn shaken(q: vec2f, hop: vec2f, t: f32) -> vec3f {
    let w = band_warp(q);
    if (any(w < vec2f(0.0)) || any(w > vec2f(1.0))) { return vec3f(0.0); }
    return scene(mirror(w - hop), t);
}

fn hash(p: vec3f) -> f32 {
    var q = fract(p * vec3f(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Banded TV static: rows grouped into bands of random brightness, grain stretched sideways.
fn static_noise(uv: vec2f, t: f32) -> f32 {
    let frame = floor((t - 0.2) * 25.0 + 0.5);
    let scale = max(globals.size.x / NOISE_W.x, globals.size.y / NOISE_W.y);
    let q = (uv - 0.5) * globals.size / scale + NOISE_W * 0.5;
    let row = floor(q.y);
    let band = floor(row / 9.0 + hash(vec3f(frame, 1.0, 2.0)) * 4.0);
    let level = pow(hash(vec3f(band, frame, 7.0)), 1.6) * 0.75;
    let grain = hash(vec3f(floor(q.x / 3.0), row, frame));
    return level * grain * grain * 0.8;
}

fn lens_params(t: f32) -> vec2f {
    if (t < 0.24) { let k = (t - 0.16) / 0.08; return vec2f(mix(26.550868, 64.764268, k), mix(131.513648, 140.0, k)); }
    if (t < 0.64) { return vec2f(64.764268, 140.0); }
    let k = (t - 0.64) / 0.16;
    return vec2f(mix(64.764268, 0.0, k), mix(140.0, 193.133047, k));
}

// The clips with the lens and the static applied, read at q.
fn scene(q: vec2f, t: f32) -> vec3f {
    var p = q;
    var inside = 1.0;
    if (t >= 0.16 && t < 0.8) {
        let lp = lens_params(t);
        let aspect = globals.size.x / globals.size.y;
        let reach = lp.y * pow(1.6, aspect - 1.0);
        var d = q - 0.5;
        d.x *= aspect;
        let r = length(d);
        let r2 = r * (1.0 - lp.x * 203.0875 / (reach * reach) * r * r);
        var w = select(vec2f(0.0), d / r * r2, r > 0.0);
        w.x /= aspect;
        p = w + 0.5;
        let edge = reach * 0.007;
        inside = smoothstep(edge + 0.001, edge - 0.001, r);
        if (any(p < vec2f(0.0)) || any(p > vec2f(1.0))) { inside = 0.0; }
    }
    var c: vec3f;
    if (t < CUT) { c = textureSampleLevel(first, smp, p, 0.0).rgb; }
    else { c = textureSampleLevel(second, smp, p, 0.0).rgb; }
    c *= inside;
    if (t >= 0.2 && t < 0.76) {
        let n = static_noise(q, t);
        c = 1.0 - (1.0 - c) * (1.0 - vec3f(n));
    }
    return c;
}

fn mirror(p: vec2f) -> vec2f {
    return abs((p - 1.0) - 2.0 * floor((p - 1.0) * 0.5) - 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0);
    if (t < 0.24 || t >= 0.72) {
        gpufx_write(id, vec4f(scene(uv, t), 1.0));
        return;
    }
    let off = FRINGE * (1.0 - uv) * uv;
    let hop = shake(t) - 0.5;
    let g = shaken(uv, hop, t);
    let r = shaken(uv + off, hop, t).r;
    let b = shaken(uv - off, hop, t).b;
    gpufx_write(id, vec4f(r, g.g, b, 1.0));
}
