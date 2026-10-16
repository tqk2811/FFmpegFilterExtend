// Both clips ride a giant turntable whose hub sits far below the frame: the first swings away
// under a sweeping arc blur while the second swings in, with a brief lens squeeze at the peak.

// Animation curves, sampled at 33 even steps of progress (lengths are in frame widths,
// angles in radians, y pointing down).
const FRONT_PIVOT = array<vec2f, 33>(
    vec2f(-0.68889, 0.34352), vec2f(-0.68889, 0.34352), vec2f(-0.68791, 0.34793), vec2f(-0.68496, 0.36126),
    vec2f(-0.67962, 0.38539), vec2f(-0.67131, 0.423), vec2f(-0.65916, 0.47808), vec2f(-0.64176, 0.55704),
    vec2f(-0.61663, 0.67134), vec2f(-0.57854, 0.84522), vec2f(-0.51357, 1.1443), vec2f(-0.43092, 1.5396),
    vec2f(-0.42691, 1.6784), vec2f(-0.44216, 2.0893), vec2f(-0.46078, 2.3361), vec2f(-0.47636, 2.4884),
    vec2f(-0.48876, 2.5923), vec2f(-0.49819, 2.6664), vec2f(-0.50485, 2.7198), vec2f(-0.50901, 2.7579),
    vec2f(-0.51102, 2.784), vec2f(-0.51146, 2.8003), vec2f(-0.51122, 2.8086), vec2f(-0.51111, 2.8102),
    vec2f(-0.51111, 2.8102), vec2f(-0.51111, 2.8102), vec2f(-0.51111, 2.8102), vec2f(-0.51111, 2.8102),
    vec2f(-0.51111, 2.8102), vec2f(-0.51111, 2.8102), vec2f(-0.51111, 2.8102), vec2f(-0.51111, 2.8102),
    vec2f(-0.51111, 2.8102),
);

const FRONT_TURN = array<f32, 33>(
    0.0, 0.0, -0.032224, -0.15836, -0.44751, -1.0538, -2.1391, -3.2208,
    -3.9721, -4.5013, -4.8952, -5.1998, -5.4411, -5.6348, -5.7914, -5.9181,
    -6.0201, -6.1013, -6.1646, -6.2126, -6.2469, -6.2693, -6.2809, -6.2832,
    -6.2832, -6.2832, -6.2832, -6.2832, -6.2832, -6.2832, -6.2832, -6.2832,
    -6.2832,
);

const FRONT_ALPHA = array<f32, 33>(
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 0.89584, 0.73438, 0.57292, 0.41146,
    0.25, 0.088544, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0,
);

const BACK_PIVOT = array<vec2f, 33>(
    vec2f(-0.51111, 1.9509), vec2f(-0.51111, 1.9509), vec2f(-0.51069, 1.9489), vec2f(-0.50959, 1.9435),
    vec2f(-0.50768, 1.9343), vec2f(-0.50476, 1.9201), vec2f(-0.50052, 1.8996), vec2f(-0.49449, 1.8706),
    vec2f(-0.48585, 1.8294), vec2f(-0.47306, 1.7689), vec2f(-0.45332, 1.6779), vec2f(-0.43057, 1.5819),
    vec2f(-0.42691, 1.6784), vec2f(-0.44216, 2.0893), vec2f(-0.46078, 2.3361), vec2f(-0.47636, 2.4884),
    vec2f(-0.48876, 2.5923), vec2f(-0.49819, 2.6664), vec2f(-0.50485, 2.7198), vec2f(-0.50901, 2.7579),
    vec2f(-0.51102, 2.784), vec2f(-0.51146, 2.7988), vec2f(-0.51141, 2.8031), vec2f(-0.51134, 2.8054),
    vec2f(-0.51127, 2.807), vec2f(-0.51122, 2.8081), vec2f(-0.51118, 2.8089), vec2f(-0.51115, 2.8094),
    vec2f(-0.51113, 2.8098), vec2f(-0.51112, 2.81), vec2f(-0.51111, 2.8102), vec2f(-0.51111, 2.8102),
    vec2f(-0.51111, 2.8102),
);

const BACK_TURN = array<f32, 33>(
    0.0, 0.0, -0.044616, -0.21319, -0.56727, -1.1731, -1.9933, -2.826,
    -3.5288, -4.0896, -4.536, -4.8949, -5.186, -5.4235, -5.6178, -5.7762,
    -5.9047, -6.0074, -6.088, -6.1491, -6.1932, -6.2216, -6.2402, -6.2537,
    -6.2634, -6.2705, -6.2754, -6.2788, -6.281, -6.2824, -6.283, -6.2832,
    -6.2832,
);

const SWEEP_ANGLE = array<f32, 33>(
    0.0, 0.0, 0.0067827, 0.025973, 0.052014, 0.078948, 0.10299, 0.12258,
    0.13743, 0.14781, 0.15414, 0.15689, 0.15484, 0.14136, 0.11653, 0.087518,
    0.061589, 0.041142, 0.025881, 0.014921, 0.0074382, 0.0027808, 0.00045203, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0,
);

const SWEEP_CENTER = array<vec2f, 33>(
    vec2f(-0.62222, 0.4), vec2f(-0.62222, 0.4), vec2f(-0.61778, 0.40941), vec2f(-0.60271, 0.44134),
    vec2f(-0.57507, 0.49991), vec2f(-0.53273, 0.58961), vec2f(-0.47372, 0.71465), vec2f(-0.39699, 0.87723),
    vec2f(-0.30374, 1.0748), vec2f(-0.19859, 1.2976), vec2f(-0.08916, 1.5295), vec2f(0.0165, 1.7533),
    vec2f(0.11258, 1.9569), vec2f(0.19634, 2.1344), vec2f(0.2673, 2.2847), vec2f(0.32621, 2.4096),
    vec2f(0.37428, 2.5114), vec2f(0.41279, 2.593), vec2f(0.44293, 2.6569), vec2f(0.46576, 2.7052),
    vec2f(0.48217, 2.74), vec2f(0.49293, 2.7628), vec2f(0.49867, 2.775), vec2f(0.5, 2.7778),
    vec2f(0.5, 2.7778), vec2f(0.5, 2.7778), vec2f(0.5, 2.7778), vec2f(0.5, 2.7778),
    vec2f(0.5, 2.7778), vec2f(0.5, 2.7778), vec2f(0.5, 2.7778), vec2f(0.5, 2.7778),
    vec2f(0.5, 2.7778),
);

const SWELL = array<f32, 33>(
    0.0, 0.0, 0.0049439, 0.019032, 0.040088, 0.065931, 0.094378, 0.12325,
    0.15036, 0.17352, 0.19057, 0.19931, 0.19807, 0.18765, 0.16914, 0.14447,
    0.11631, 0.087566, 0.060822, 0.037978, 0.020177, 0.0079373, 0.0013442, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0,
);

const PINCH = array<f32, 33>(
    0.0, 0.0, -0.0094641, -0.036433, -0.076741, -0.12621, -0.18067, -0.23593,
    -0.28783, -0.33218, -0.3648, -0.38153, -0.37911, -0.3584, -0.32082, -0.27039,
    -0.21349, -0.157, -0.10638, -0.064858, -0.033715, -0.01301, -0.0021668, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0,
);

const EDGE_BOTTOM = array<vec2f, 33>(
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3212, 0.6515), vec2f(0.2892, 0.6120),
    vec2f(0.2445, 0.5571), vec2f(0.1950, 0.4961), vec2f(0.1481, 0.4384), vec2f(0.1116, 0.3935),
    vec2f(0.0932, 0.3708), vec2f(0.0977, 0.3764), vec2f(0.1199, 0.4037), vec2f(0.1543, 0.4460),
    vec2f(0.1958, 0.4971), vec2f(0.2392, 0.5506), vec2f(0.2796, 0.6002), vec2f(0.3116, 0.6397),
    vec2f(0.3303, 0.6627), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660),
);

const EDGE_TOP = array<vec2f, 33>(
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3201, 0.6462), vec2f(0.2851, 0.5925),
    vec2f(0.2364, 0.5176), vec2f(0.1822, 0.4345), vec2f(0.1310, 0.3559), vec2f(0.0912, 0.2947),
    vec2f(0.0710, 0.2638), vec2f(0.0760, 0.2715), vec2f(0.1002, 0.3086), vec2f(0.1378, 0.3663),
    vec2f(0.1831, 0.4358), vec2f(0.2306, 0.5088), vec2f(0.2746, 0.5764), vec2f(0.3097, 0.6302),
    vec2f(0.3300, 0.6615), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660),
);

const EDGE_LEFT = array<vec2f, 33>(
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3510, 0.6782), vec2f(0.3998, 0.7112),
    vec2f(0.4677, 0.7572), vec2f(0.5433, 0.8083), vec2f(0.6146, 0.8566), vec2f(0.6702, 0.8942),
    vec2f(0.6983, 0.9132), vec2f(0.6913, 0.9085), vec2f(0.6576, 0.8857), vec2f(0.6052, 0.8502),
    vec2f(0.5420, 0.8075), vec2f(0.4758, 0.7627), vec2f(0.4144, 0.7211), vec2f(0.3655, 0.6880),
    vec2f(0.3371, 0.6688), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660),
);

const EDGE_RIGHT = array<vec2f, 33>(
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3403, 0.6782), vec2f(0.3600, 0.7112),
    vec2f(0.3874, 0.7572), vec2f(0.4180, 0.8083), vec2f(0.4468, 0.8566), vec2f(0.4692, 0.8942),
    vec2f(0.4806, 0.9132), vec2f(0.4778, 0.9085), vec2f(0.4642, 0.8857), vec2f(0.4430, 0.8502),
    vec2f(0.4175, 0.8075), vec2f(0.3907, 0.7627), vec2f(0.3659, 0.7211), vec2f(0.3461, 0.6880),
    vec2f(0.3347, 0.6688), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660), vec2f(0.3330, 0.6660),
    vec2f(0.3330, 0.6660),
);


// Where each clip's centre sits relative to the hub, in frame widths.
const FRONT_ARM: vec2f = vec2f(0.688889, -0.343519);
const BACK_ARM: vec2f = vec2f(0.511111, -2.810185);
// Arc blur taps on each side of the pixel.
const SWEEP_TAPS: i32 = 28;
// Swell of the lower-left area at the peak (centre offset and taper of the dome).
const SWELL_SHIFT: vec2f = vec2f(0.17, 0.55);
const SWELL_TAPER: f32 = 0.4;
// Centre of the lens squeeze (y up) and the frame-to-lens scale.
const PINCH_CENTER: vec2f = vec2f(0.5, 0.834259);

struct Curve { i: u32, j: u32, f: f32 }

var<private> cur: Curve;

fn f1(t: array<f32, 33>) -> f32 {
    var a = t;
    return mix(a[cur.i], a[cur.j], cur.f);
}

fn f2(t: array<vec2f, 33>) -> vec2f {
    var a = t;
    return mix(a[cur.i], a[cur.j], cur.f);
}

// Mirror-repeat coordinates so a clip tiles seamlessly past its borders.
fn mirror(q: vec2f) -> vec2f {
    let m = q - 2.0 * floor(q * 0.5);
    return select(m, 2.0 - m, m > vec2f(1.0));
}

fn turn(v: vec2f, a: f32) -> vec2f {
    let c = cos(a);
    let s = sin(a);
    return vec2f(c * v.x - s * v.y, s * v.x + c * v.y);
}

struct Rig {
    front_hub: vec2f,
    front_angle: f32,
    front_alpha: f32,
    back_hub: vec2f,
    back_angle: f32,
}

// The two clips on their arms, the first one on top fading out (y down).
fn scene(rig: Rig, c: vec2f) -> vec3f {
    let back_uv = turn(c - rig.back_hub, -rig.back_angle) - BACK_ARM;
    let back = textureSampleLevel(second, smp, mirror(back_uv), 0.0).rgb;
    if (rig.front_alpha <= 0.0) { return back; }
    let front_uv = turn(c - rig.front_hub, -rig.front_angle) - FRONT_ARM;
    let front = textureSampleLevel(first, smp, mirror(front_uv), 0.0).rgb;
    return mix(back, front, rig.front_alpha);
}

// Cubic Bezier through 0, a, b, 1.
fn edge_curve(h: vec2f, u: f32) -> f32 {
    let v = 1.0 - u;
    return 3.0 * v * v * u * h.x + 3.0 * v * u * u * h.y + u * u * u;
}

// Inverse of edge_curve (monotonic), by bisection.
fn edge_inverse(h: vec2f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var k = 0; k < 16; k++) {
        let m = 0.5 * (lo + hi);
        if (edge_curve(h, m) > x) { hi = m; } else { lo = m; }
    }
    return 0.5 * (lo + hi);
}

// The frame's content slides along its edges: the texture point u lands at a blend of the
// four edge curves. Undo that map with a few alternating passes (y up).
fn unslide(q: vec2f, bottom: vec2f, top: vec2f, left: vec2f, right: vec2f) -> vec2f {
    var u = q;
    for (var k = 0; k < 3; k++) {
        let hx = mix(bottom, top, u.y);
        u.x = edge_inverse(hx, q.x);
        let hy = mix(left, right, u.x);
        u.y = edge_inverse(hy, q.y);
    }
    return u;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0);
    let k = t * 32.0;
    cur = Curve(u32(floor(k)), min(u32(floor(k)) + 1u, 32u), fract(k));
    let aspect = globals.size.x / globals.size.y;

    // Work with y up from here, like the lens stages are defined.
    var q = vec2f(uv.x, 1.0 - uv.y);
    q = unslide(q, f2(EDGE_BOTTOM), f2(EDGE_TOP), f2(EDGE_LEFT), f2(EDGE_RIGHT));

    // Lens squeeze toward a point near the top; outside the frame turns black.
    var d = q - PINCH_CENTER;
    d.x *= aspect;
    let r = length(d);
    d *= 1.0 + f1(PINCH) * r * r;
    d.x /= aspect;
    q = PINCH_CENTER + d;
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) {
        gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0));
        return;
    }

    // Dome swelling up out of the lower-left area.
    let dome = 1.0 - length(q - 0.5 + SWELL_SHIFT);
    let mask = smoothstep(SWELL_TAPER * SWELL_TAPER - 0.001, sqrt(SWELL_TAPER) + 0.001, dome) * dome;
    let off = q - 0.5;
    q = 0.5 + off - off * (2.0 - length(off)) * f1(SWELL) * sqrt(max(mask, 0.0));

    let rig = Rig(f2(FRONT_PIVOT), f1(FRONT_TURN), f1(FRONT_ALPHA), f2(BACK_PIVOT), f1(BACK_TURN));
    let p = vec2f(q.x, 1.0 - q.y);

    // Arc blur around a point that follows the hub: taps rotate both ways; taps that leave
    // the frame are skipped.
    let sweep = f1(SWEEP_ANGLE);
    var acc = scene(rig, p);
    var total = 1.0;
    if (sweep > 0.0005) {
        let hub = f2(SWEEP_CENTER);
        let step = sweep / f32(SWEEP_TAPS);
        for (var n = 1; n <= SWEEP_TAPS; n++) {
            for (var side = -1.0; side <= 1.0; side += 2.0) {
                var v = p - hub;
                v.y /= aspect;
                v = turn(v, side * step * f32(n));
                v.y *= aspect;
                let s = hub + v;
                if (all(s >= vec2f(0.0)) && all(s <= vec2f(1.0))) {
                    acc += scene(rig, s);
                    total += 1.0;
                }
            }
        }
    }
    gpufx_write(id, vec4f(acc / total, 1.0));
}
