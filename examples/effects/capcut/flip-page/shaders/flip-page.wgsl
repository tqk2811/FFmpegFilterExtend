// Three pages peel off from the bottom-left corner one after another (two of the first clip,
// then one of the second) under a diagonal streak blur, uncovering the second clip.

// Animation curves, sampled at 43 even steps of progress (y up; SLIDE_POS is the offset of
// the second clip from its resting place).
const PAGE1_FOLD = array<vec2f, 43>(
    vec2f(0.5, 0.5), vec2f(0.54252, 0.53722), vec2f(0.58503, 0.57444), vec2f(0.62755, 0.61166),
    vec2f(0.67007, 0.64888), vec2f(0.71258, 0.6861), vec2f(0.7551, 0.72331), vec2f(0.79762, 0.76053),
    vec2f(0.84013, 0.79775), vec2f(0.88265, 0.83497), vec2f(0.92517, 0.87219), vec2f(0.96768, 0.90941),
    vec2f(1.0102, 0.94663), vec2f(1.0527, 0.98385), vec2f(1.0952, 1.0211), vec2f(1.1378, 1.0583),
    vec2f(1.1803, 1.0955), vec2f(1.2228, 1.1327), vec2f(1.2653, 1.1699), vec2f(1.3078, 1.2072),
    vec2f(1.3503, 1.2444), vec2f(1.3929, 1.2816), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
);

const PAGE1_RADIUS = array<f32, 43>(
    5.0, 4.7986, 4.5973, 4.3959, 4.1945, 3.9932, 3.7918, 3.5905,
    3.3891, 3.1877, 2.9864, 2.785, 2.5836, 2.3823, 2.1809, 1.9795,
    1.7782, 1.5768, 1.3755, 1.1741, 0.97273, 0.77137, 0.57, 0.57,
    0.57, 0.57, 0.57, 0.57, 0.57, 0.57, 0.57, 0.57,
    0.57, 0.57, 0.57, 0.57, 0.57, 0.57, 0.57, 0.57,
    0.57, 0.57, 0.57,
);

const PAGE2_FOLD = array<vec2f, 43>(
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.54252, 0.53722),
    vec2f(0.58503, 0.57444), vec2f(0.62755, 0.61166), vec2f(0.67007, 0.64888), vec2f(0.71258, 0.6861),
    vec2f(0.7551, 0.72331), vec2f(0.79762, 0.76053), vec2f(0.84013, 0.79775), vec2f(0.88265, 0.83497),
    vec2f(0.92517, 0.87219), vec2f(0.96768, 0.90941), vec2f(1.0102, 0.94663), vec2f(1.0527, 0.98385),
    vec2f(1.0952, 1.0211), vec2f(1.1378, 1.0583), vec2f(1.1803, 1.0955), vec2f(1.2228, 1.1327),
    vec2f(1.2653, 1.1699), vec2f(1.3078, 1.2072), vec2f(1.3503, 1.2444), vec2f(1.3929, 1.2816),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
);

const PAGE2_RADIUS = array<f32, 43>(
    5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 4.7986,
    4.5973, 4.3959, 4.1945, 3.9932, 3.7918, 3.5905, 3.3891, 3.1877,
    2.9864, 2.785, 2.5836, 2.3823, 2.1809, 1.9795, 1.7782, 1.5768,
    1.3755, 1.1741, 0.97273, 0.77137, 0.57, 0.57, 0.57, 0.57,
    0.57, 0.57, 0.57, 0.57, 0.57, 0.57, 0.57, 0.57,
    0.57, 0.57, 0.57,
);

const PAGE3_FOLD = array<vec2f, 43>(
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5), vec2f(0.54677, 0.54094), vec2f(0.59354, 0.58188), vec2f(0.64031, 0.62282),
    vec2f(0.68707, 0.66376), vec2f(0.73384, 0.70471), vec2f(0.78061, 0.74565), vec2f(0.82738, 0.78659),
    vec2f(0.87415, 0.82753), vec2f(0.92092, 0.86847), vec2f(0.96769, 0.90941), vec2f(1.0145, 0.95035),
    vec2f(1.0612, 0.99129), vec2f(1.108, 1.0322), vec2f(1.1548, 1.0732), vec2f(1.2015, 1.1141),
    vec2f(1.2483, 1.1551), vec2f(1.2951, 1.196), vec2f(1.3418, 1.2369), vec2f(1.3886, 1.2779),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
    vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188), vec2f(1.4354, 1.3188),
);

const PAGE3_RADIUS = array<f32, 43>(
    5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0,
    5.0, 5.0, 5.0, 5.0, 5.0, 4.7785, 4.557, 4.3355,
    4.114, 3.8925, 3.671, 3.4495, 3.228, 3.0065, 2.785, 2.5635,
    2.342, 2.1205, 1.899, 1.6775, 1.456, 1.2345, 1.013, 0.7915,
    0.57, 0.57, 0.57, 0.57, 0.57, 0.57, 0.57, 0.57,
    0.57, 0.57, 0.57,
);

const PAGE3_SCALE = array<f32, 43>(
    1.02, 1.02, 1.02, 1.02, 1.02, 1.02, 1.02, 1.02,
    1.02, 1.02, 1.02, 1.0191, 1.0182, 1.0173, 1.0164, 1.0155,
    1.0145, 1.0136, 1.0127, 1.0118, 1.0109, 1.01, 1.0091, 1.0082,
    1.0073, 1.0064, 1.0055, 1.0045, 1.0036, 1.0027, 1.0018, 1.0009,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0,
);

const SLIDE_POS = array<vec2f, 43>(
    vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594),
    vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594),
    vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594),
    vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594),
    vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594),
    vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594), vec2f(-0.07254, -0.054594),
    vec2f(-0.07254, -0.054594), vec2f(-0.062203, -0.047153), vec2f(-0.054581, -0.041663), vec2f(-0.047593, -0.036616),
    vec2f(-0.040309, -0.031321), vec2f(-0.030014, -0.023697), vec2f(-0.019925, -0.016078), vec2f(-0.013244, -0.010974),
    vec2f(-0.007806, -0.0066849), vec2f(-0.0054428, -0.0047297), vec2f(-0.0035473, -0.0031048), vec2f(-0.0017778, -0.001557),
    vec2f(0, 0), vec2f(0, 0), vec2f(0, 0), vec2f(0, 0),
    vec2f(0, 0), vec2f(0, 0), vec2f(0, 0),
);

const SLIDE_SPIN = array<f32, 43>(
    -0.028716, -0.028716, -0.028716, -0.028716, -0.028716, -0.028716, -0.028716, -0.028716,
    -0.028716, -0.028716, -0.028716, -0.028716, -0.028716, -0.028716, -0.028716, -0.028716,
    -0.028716, -0.028716, -0.028716, -0.028716, -0.028716, -0.028716, -0.028716, -0.028716,
    -0.028716, -0.025689, -0.023469, -0.021409, -0.019154, -0.015254, -0.01121, -0.00799,
    -0.0051762, -0.003714, -0.0024445, -0.0012244, 0, 0, 0, 0,
    0, 0, 0,
);


const STREAK = array<f32, 43>(
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    3.0028e-11, 0.090141, 0.36822, 0.84667, 1.5393, 2.4617, 3.631, 5.0664,
    6.7893, 8.8228, 11.191, 13.917, 17.016, 20.476, 24.21, 27.867,
    30.0, 29.733, 28.971, 27.778, 26.214, 24.342, 22.222, 19.918,
    17.49, 15.0, 12.51, 10.082, 7.7778, 5.6584, 3.786, 2.2222,
    1.0288, 0.26749, 0.0,
);


// When each layer is on screen, in progress units.
const PLAIN_END: f32 = 0.047619;
const PAGE1_SPAN: vec2f = vec2f(0.0, 0.52381);
const PAGE2_SPAN: vec2f = vec2f(0.095238, 0.666667);
const PAGE3_SPAN: vec2f = vec2f(0.238095, 0.761905);
const SLIDE_START: f32 = 0.285714;
const SOFT_END: f32 = 0.333333;
// The page lifts from this corner.
const CORNER: vec2f = vec2f(0.0, 0.0);
// Shade of the page's back side.
const BACK_SHADE: f32 = 0.7;
// Streak direction (radians from +x, y up) and the length of one tap in 720-pixel units.
const STREAK_ANGLE: f32 = 0.698132;
const STREAK_UNIT: f32 = 1.0 / 720.0;
const HALF_PI: f32 = 1.5707963;

struct Curve { i: u32, j: u32, f: f32 }

var<private> cur: Curve;

fn f1(t: array<f32, 43>) -> f32 {
    var a = t;
    return mix(a[cur.i], a[cur.j], cur.f);
}

fn f2(t: array<vec2f, 43>) -> vec2f {
    var a = t;
    return mix(a[cur.i], a[cur.j], cur.f);
}

fn inside(u: vec2f) -> f32 {
    return select(0.0, 1.0, all(u >= vec2f(0.0)) && all(u <= vec2f(1.0)));
}

// Line a*x + b*y + c = 0 stored as (a, b, c).
fn line_dist(p: vec2f, l: vec3f) -> f32 {
    return abs(dot(l.xy, p) + l.z) / length(l.xy);
}

fn reflect_on(p: vec2f, l: vec3f) -> vec2f {
    let a = l.x;
    let b = l.y;
    let n = a * a + b * b;
    return vec2f(((b * b - a * a) * p.x - 2.0 * a * (b * p.y + l.z)) / n,
                 ((a * a - b * b) * p.y - 2.0 * b * (a * p.x + l.z)) / n);
}

// Same line moved by `d` (in units of its normal).
fn shifted(l: vec3f, d: f32) -> vec3f {
    return vec3f(l.xy, l.z - d * length(l.xy));
}

fn read_clip(use_second: bool, uv: vec2f, zoom: f32) -> vec4f {
    let p = (uv - 0.5) / zoom + 0.5;
    let s = vec2f(p.x, 1.0 - p.y);
    if (use_second) { return textureSampleLevel(second, smp, s, 0.0); }
    return textureSampleLevel(first, smp, s, 0.0);
}

// A page curling around a cylinder whose axis runs across the corner-to-fold diagonal.
// Returns colour with coverage in alpha.
fn page(uv: vec2f, use_second: bool, fold_in: vec2f, radius_in: f32, zoom: f32) -> vec4f {
    let fold = fold_in + vec2f(1e-8);
    var corner = CORNER;
    corner.x = min(fold.x - 0.001, corner.x);
    corner.y = min(fold.y - 0.001, corner.y);
    let radius = max(radius_in, 1e-8);
    let toward = normalize(fold - corner);
    let mid = 0.5 * (corner + fold);
    let arc = HALF_PI * radius;

    let diag = vec3f(corner.y - fold.y, fold.x - corner.x, corner.x * fold.y - corner.y * fold.x);
    let edge = vec3f(diag.y, -diag.x, diag.x * fold.y - diag.y * fold.x);
    let leaning = sign(edge.x / (edge.y + 1e-8));
    let crease = vec3f(diag.y, -diag.x, diag.x * mid.y - diag.y * mid.x);

    var roll = shifted(crease, arc);
    var outer = false;
    if (leaning < 0.0) {
        if (edge.z - roll.z > 0.0) { roll.z = edge.z; outer = true; }
    } else {
        if (roll.z - edge.z < 0.0) { roll.z = edge.z; outer = true; }
    }

    var a = vec2f((-roll.z - roll.y * corner.y) / (roll.x + 1e-8), corner.y);
    var b = vec2f(corner.x, (-roll.z - roll.x * corner.x) / (roll.y + 1e-8));
    if (leaning > 0.0) { let t = a; a = b; b = t; }
    let e = a - b;
    let w = a - uv;
    let flat_side = select(0.0, 1.0, e.x * w.y - e.y * w.x > 0.0);

    // Part of the page wrapped on the cylinder.
    let d = line_dist(uv, roll);
    let on_roll = select(0.0, 1.0, d <= radius + 0.001);
    let theta = asin(min(d / max(radius, 1e-4), 1.0)) * on_roll;
    let wrapped = clamp(uv - toward * (theta * radius - d), vec2f(-10.0), vec2f(10.0));
    let under_uv = mix(wrapped * inside(wrapped), uv, flat_side);
    var under = read_clip(use_second, under_uv, zoom);
    under *= clamp(flat_side + inside(wrapped), 0.0, 1.0);
    let rolled = under * select(0.0, 1.0, d <= radius + 0.0001);
    under = mix(under * flat_side, rolled, rolled.a);

    // The page's back side, mirrored over the crease.
    var mirror_line = crease;
    if (outer) { mirror_line = shifted(roll, -arc); }
    let mirrored = reflect_on(uv, mirror_line);
    let flat_back = flat_side * inside(mirrored);
    let rolled_back_uv = reflect_on(wrapped, mirror_line);
    let rolled_back = inside(rolled_back_uv) * (1.0 - flat_side) * on_roll;
    var back = read_clip(use_second, mix(mirrored, rolled_back_uv, rolled_back), zoom);
    back *= clamp(rolled_back + flat_back, 0.0, 1.0);
    back = vec4f(back.rgb * BACK_SHADE, back.a);

    var res = mix(back, vec4f(0.0), 0.0);
    res = mix(under, res, res.a);
    return res * inside(uv);
}

fn over(top: vec4f, below: vec3f) -> vec3f {
    return mix(below, top.rgb, top.a);
}

fn in_span(t: f32, s: vec2f) -> bool {
    return t >= s.x && t < s.y;
}

// Layer stack, bottom to top (y up).
fn stack(uv: vec2f, t: f32) -> vec3f {
    var c = vec3f(0.0);
    if (t < SOFT_END) {
        c = read_clip(false, uv, 1.02).rgb;
    }
    if (t >= SLIDE_START) {
        var v = uv - 0.5 - f2(SLIDE_POS);
        let a = f1(SLIDE_SPIN);
        v = vec2f(cos(a) * v.x + sin(a) * v.y, -sin(a) * v.x + cos(a) * v.y);
        let p = abs((v + 0.5 - 1.0) - 2.0 * floor((v + 0.5 - 1.0) * 0.5) - 1.0);
        c = textureSampleLevel(second, smp, vec2f(p.x, 1.0 - p.y), 0.0).rgb;
    }
    if (in_span(t, PAGE3_SPAN)) { c = over(page(uv, true, f2(PAGE3_FOLD), f1(PAGE3_RADIUS), f1(PAGE3_SCALE)), c); }
    if (in_span(t, PAGE2_SPAN)) { c = over(page(uv, false, f2(PAGE2_FOLD), f1(PAGE2_RADIUS), 1.0), c); }
    if (in_span(t, PAGE1_SPAN)) { c = over(page(uv, false, f2(PAGE1_FOLD), f1(PAGE1_RADIUS), 1.0), c); }
    if (t < PLAIN_END) { c = read_clip(false, uv, 1.0).rgb; }
    return c;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let k = t * 42.0;
    cur = Curve(u32(floor(k)), min(u32(floor(k)) + 1u, 42u), fract(k));
    let q = vec2f(uv.x, 1.0 - uv.y);

    // Gaussian streak along a fixed diagonal; its length follows the curve.
    let taps = floor(f1(STREAK));
    let side = min(globals.size.x, globals.size.y);
    let step = vec2f(cos(STREAK_ANGLE), sin(STREAK_ANGLE)) * STREAK_UNIT * side / globals.size;
    var acc = stack(q, t) * 0.0997356;
    var total = 0.0997356;
    for (var n = 1.0; n <= taps; n += 1.0) {
        let x = n / taps * 15.0;
        let w = 0.0997356 * exp(-0.5 * x * x / 16.0);
        acc += w * (stack(clamp(q + step * n, vec2f(0.0), vec2f(1.0)), t)
                  + stack(clamp(q - step * n, vec2f(0.0), vec2f(1.0)), t));
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(acc / total, 1.0));
}
