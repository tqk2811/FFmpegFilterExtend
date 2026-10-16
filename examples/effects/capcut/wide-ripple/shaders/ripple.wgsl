// Wide Ripple, pass 2: a fading zoom blur seen through a pinching wide lens, toned warm, with fine film grain.
//
// The look fades in over 0.733..0.8 s and out over 1.4..1.467 s of the 2 s timeline. Outside the
// lens circle the plain moving picture shows through.

const SPAN: f32 = 2.0;
const MID_TONE: vec3f = vec3f(0.6, 0.52156866, 0.3529412);

fn bez(a: f32, b: f32, c: f32, d: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return a * r * r * r + 3.0 * b * r * r * s + 3.0 * c * r * s * s + d * s * s * s;
}

fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 18; i++) {
        let mid = 0.5 * (lo + hi);
        if (bez(0.0, e.x, e.z, 1.0, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bez(0.0, e.y, e.w, 1.0, 0.5 * (lo + hi));
}

// smoothstep that also accepts a falling edge (lo_edge > hi_edge)
fn ramp(lo_edge: f32, hi_edge: f32, x: f32) -> f32 {
    let k = clamp((x - lo_edge) / (hi_edge - lo_edge), 0.0, 1.0);
    return k * k * (3.0 - 2.0 * k);
}

fn look_strength(t: f32) -> f32 {
    if (t < 0.733333) { return 0.0; }
    if (t < 0.8) { return (t - 0.733333) / 0.066667; }
    if (t < 1.4) { return 1.0; }
    if (t < 1.466667) { return 1.0 - (t - 1.4) / 0.066667; }
    return 0.0;
}

fn zoom_amount(t: f32) -> f32 {
    if (t < 0.733333) { return 0.0; }
    if (t < 1.0) { return 20.0 * (t - 0.733333) / 0.266667; }
    if (t < 1.233333) { return 20.0 * (1.0 - (t - 1.0) / 0.233333); }
    return 0.0;
}

fn lens_pinch(t: f32) -> f32 {
    if (t < 0.733333) { return 7.0; }
    if (t < 1.0) { return mix(7.0, 33.0, ease(vec4f(0.33333333, 0.0, 0.66666667, 1.0), (t - 0.733333) / 0.266667)); }
    if (t < 1.233333) { return mix(33.0, 100.0, ease(vec4f(0.33333333, 0.0, 0.833333333, 1.0), (t - 1.0) / 0.233333)); }
    return 100.0;
}

fn lens_size(t: f32) -> f32 {
    if (t < 1.0) { return 103.0; }
    if (t < 1.233333) { return mix(103.0, 151.0, ease(vec4f(0.47737715, -0.026357991, 0.683852222, 0.263853806), (t - 1.0) / 0.233333)); }
    if (t < 1.4) { return mix(151.0, 500.0, ease(vec4f(0.983718948, 0.399928941, 0.833333333, 1.0), (t - 1.233333) / 0.166667)); }
    return 500.0;
}

fn scatter(p: vec2f) -> f32 {
    let f = fract(p * 13.517);
    let g = f + dot(f, f.yx + vec2f(22.541));
    return fract((g.x + g.y) * g.y);
}

// Zoom blur towards the centre whose taps fade with distance; taps off the frame count as black.
fn fading_zoom(q: vec2f, amount: f32) -> vec4f {
    let reach = (q - vec2f(0.5)) * (amount / 200.0);
    let len = length(reach);
    let n = min(160.0 * sign(len) * (0.9 * len + 0.1) + 5.0, 128.0);
    let stride = reach / n;
    let fade = pow(pow(0.965, 50.0), 1.0 / n);
    let start = q + stride * (0.5 * (scatter(q) * 2.0 - 1.0));
    var acc = textureSampleLevel(layered, smp, q, 0.0);
    var total = 1.0;
    var w = 1.0;
    for (var i = 1.0; i <= 128.0; i += 1.0) {
        if (i > n) { break; }
        w *= fade;
        let s = start - stride * i;
        if (all(s >= vec2f(0.0)) && all(s <= vec2f(1.0))) {
            acc += textureSampleLevel(layered, smp, s, 0.0) * w;
        }
        total += w;
    }
    return acc / total;
}

// Lattice gradient noise; the cell size is `cell` in units of p.
fn grain_hash(p: vec2f, seed: f32) -> vec2f {
    var h = fract(p.xyx * vec3f(0.1031, 0.103, 0.0973));
    h += vec3f(dot(h, h.yzx + vec3f(33.33) + vec3f(seed)));
    return fract((h.xx + h.yz) * h.zy) * 2.0 - vec2f(1.0);
}

fn grain_cell(p: vec2f, cell: f32, seed: f32, coarse: f32) -> f32 {
    let i = floor(p / cell);
    let f = fract(p / cell);
    let soft = f * f * (f * (f * 6.0 - vec2f(15.0)) + vec2f(10.0));
    let u = mix(f * soft, soft, vec2f(ramp(0.3, 0.25, coarse)));
    let a = dot(grain_hash(i * cell, seed), f);
    let b = dot(grain_hash((i + vec2f(1.0, 0.0)) * cell, seed), f - vec2f(1.0, 0.0));
    let c = dot(grain_hash((i + vec2f(0.0, 1.0)) * cell, seed), f - vec2f(0.0, 1.0));
    let d = dot(grain_hash((i + vec2f(1.0)) * cell, seed), f - vec2f(1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn grain_value(p: vec2f, coarse: f32, seed: f32) -> f32 {
    let octave = 2.0 / max(0.1, coarse);
    let base = floor(octave);
    let c0 = pow(2.0, base);
    let c1 = pow(2.0, base + 1.0);
    let g0 = 0.6 * (grain_cell(p * 500.0, 500.0 / c0, seed, coarse) * 0.5 + 0.5)
        + 0.4 * (grain_cell(p * 300.0, 300.0 / c0, seed, coarse) * 0.5 + 0.5);
    let g1 = 0.6 * (grain_cell(p * 500.0, 500.0 / c1, seed, coarse) * 0.5 + 0.5)
        + 0.4 * (grain_cell(p * 300.0, 300.0 / c1, seed, coarse) * 0.5 + 0.5);
    // contrast boost x11 around 0.5
    return (mix(g0, g1, fract(octave)) - 0.5) * 11.0 + 0.5;
}

fn overlay(b: f32, n: f32) -> f32 {
    if (b < 0.5) { return 2.0 * b * n; }
    return 1.0 - 2.0 * (1.0 - b) * (1.0 - n);
}

fn film_grain(c: vec3f, p: vec2f, t: f32) -> vec3f {
    let seed = (t * 1000.0) % 100.0;
    let n = vec3f(grain_value(p, 0.2, seed), grain_value(p, 0.2, seed + 2.0), grain_value(p, 0.2, seed + 4.0));
    let o = vec3f(overlay(c.r, n.r), overlay(c.g, n.g), overlay(c.b, n.b));
    let lift = max(vec3f(1.0) - (vec3f(1.0) - n) / 0.5, vec3f(0.0));
    let lum = dot(c, vec3f(0.299, 0.587, 0.114));
    let film = mix(o, vec3f(1.0) - (vec3f(1.0) - o) * (vec3f(1.0) - lift), vec3f(0.5 * ramp(0.58823532, 0.50980395, lum)));
    return mix(c, film, 0.01);
}

fn shadows_highlights(c: vec3f) -> vec3f {
    let hi = 1.0522808; // highlights +0.1
    let lo = 1.1719054; // shadows -0.3
    let h = clamp(vec3f(1.0) - c, vec3f(0.0), vec3f(1.0));
    let a = vec3f(1.0) - pow(h, vec3f(hi)) - (h * h - h * h * h) * (hi - 1.0);
    let a2 = max(a, vec3f(0.0));
    return clamp(pow(a2, vec3f(lo)) + (a2 * a2 - a2 * a2 * a2) * (lo - 1.0), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let plain = textureSampleLevel(layered, smp, uv, 0.0);
    let strength = look_strength(t);
    if (strength <= 0.0) { gpufx_write(id, vec4f(plain.rgb, 1.0)); return; }

    // Wide lens: pull the picture in towards the centre, clipped to a circle.
    let aspect = globals.size.x / globals.size.y;
    let size = lens_size(t);
    var d = uv - vec2f(0.5);
    d.x *= aspect;
    let dist = length(d);
    let bent = dist * (1.0 - lens_pinch(t) * 203.0875 / (size * size) * dist * dist);
    var dir = vec2f(0.0);
    if (dist > 0.0) { dir = d / dist; }
    var q = dir * bent;
    q.x /= aspect;
    q += vec2f(0.5);
    let rim = size * 0.007;
    var c = vec4f(0.0);
    if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
        c = fading_zoom(q, zoom_amount(t)) * (1.0 - ramp(rim - 0.001, rim + 0.001, dist));
    }

    // Tritone (black / warm grey / white) at half strength, on the straight colour.
    let straight = c.rgb / max(c.a, 1e-4);
    let lum = dot(straight, vec3f(0.299, 0.587, 0.114));
    var tone = mix(MID_TONE, vec3f(1.0), (lum - 0.5) / 0.5);
    if (lum < 0.5) { tone = mix(vec3f(0.0), MID_TONE, lum / 0.5); }
    var rgb = mix(tone, straight, 0.5) * c.a;

    rgb = film_grain(rgb, vec2f(uv.x * aspect, 1.0 - uv.y), t);
    rgb = shadows_highlights(rgb);

    // The treated picture goes over the plain one, faded by the strength.
    let over = rgb + plain.rgb * (1.0 - c.a);
    gpufx_write(id, vec4f(mix(plain.rgb, over, strength), 1.0));
}
