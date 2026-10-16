// The first clip is sucked inward and shaken under a zoom blur, then the second one bursts out
// of a fisheye and settles; this pass draws the clips, the shake and the zoom streaks.

// Animation curves, sampled at 45 even steps of progress (y up, angles in radians).
const PINCH = array<f32, 45>(
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0045205,
    0.027529, 0.0731, 0.14508, 0.24714, 0.3808, 0.54094, 0.70959, 0.85672,
    0.95586, 0.99794, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0,
);

const LENS = array<vec2f, 45>(
    vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005),
    vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005),
    vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005),
    vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005), vec2f(2.1247, 2.3005),
    vec2f(2.1109, 2.2949), vec2f(2.0007, 2.2492), vec2f(1.7961, 2.1575), vec2f(1.5141, 2.0139),
    vec2f(1.1892, 1.8135), vec2f(0.86535, 1.5566), vec2f(0.58114, 1.2528), vec2f(0.35651, 0.92896),
    vec2f(0.19515, 0.62858), vec2f(0.093365, 0.3931), vec2f(0.039146, 0.23496), vec2f(0.014569, 0.13869),
    vec2f(0.004804, 0.082046), vec2f(0.0013666, 0.048349), vec2f(0.00031605, 0.027669), vec2f(5.2914e-05, 0.014657),
    vec2f(4.9946e-06, 0.0065473), vec2f(1.2937e-07, 0.0019238), vec2f(6.6346e-13, 3.3134e-05), vec2f(0, 0),
    vec2f(0, 0), vec2f(0, 0), vec2f(0, 0), vec2f(0, 0),
    vec2f(0, 0), vec2f(0, 0), vec2f(0, 0), vec2f(0, 0),
    vec2f(0, 0),
);

const ZOOM = array<f32, 45>(
    6.2039e-26, 0.00022288, 0.0009467, 0.0022753, 0.0043528, 0.0073883, 0.011705, 0.017846,
    0.026841, 0.04103, 0.06619, 0.091789, 0.099268, 0.099148, 0.087498, 0.069846,
    0.056438, 0.046419, 0.038562, 0.032187, 0.026896, 0.022438, 0.018646, 0.015401,
    0.012615, 0.010222, 0.0081691, 0.0064157, 0.0049277, 0.0036775, 0.0026418, 0.0018009,
    0.0011379, 0.00063832, 0.00028953, 8.0427e-05, 1.2281e-06, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0,
);

const SHAKE_SPIN = array<f32, 45>(
    2.9183e-13, 0.047702, 0.083582, 0.10528, 0.10923, 0.089218, 0.030599, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0,
);

const SHAKE_POS = array<vec2f, 45>(
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.51686, 0.52149), vec2f(0.51455, 0.51088), vec2f(0.48031, 0.44792), vec2f(0.50137, 0.53394),
    vec2f(0.51295, 0.54901), vec2f(0.54914, 0.47366), vec2f(0.51252, 0.47386), vec2f(0.49191, 0.47706),
    vec2f(0.51863, 0.52983), vec2f(0.5046, 0.50538), vec2f(0.48644, 0.47319), vec2f(0.51927, 0.51205),
    vec2f(0.52179, 0.51339), vec2f(0.50451, 0.48222), vec2f(0.50089, 0.4949), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5),
);

const SHAKE_SCALE_X = array<f32, 45>(
    1.0, 1.0275, 1.087, 1.1628, 1.2467, 1.3073, 1.3175, 1.3119,
    1.2963, 1.2743, 1.2485, 1.2208, 1.1927, 1.1659, 1.1419, 1.1227,
    1.1105, 1.1087, 1.1324, 1.2168, 1.2725, 1.2945, 1.3, 1.2976,
    1.2894, 1.2738, 1.2498, 1.2184, 1.1835, 1.1499, 1.1202, 1.0951,
    1.0743, 1.0572, 1.0433, 1.0319, 1.0227, 1.0155, 1.0099, 1.0057,
    1.0027, 1.0009, 1.0001, 1.0, 1.0,
);

const SHAKE_SCALE_Y = array<f32, 45>(
    1.0, 1.02, 1.0634, 1.1189, 1.1804, 1.2267, 1.2385, 1.2372,
    1.2275, 1.212, 1.1929, 1.1717, 1.15, 1.1292, 1.1106, 1.0962,
    1.088, 1.0895, 1.1184, 1.2116, 1.2705, 1.2941, 1.3, 1.2976,
    1.2894, 1.2738, 1.2498, 1.2184, 1.1835, 1.1499, 1.1202, 1.0951,
    1.0743, 1.0572, 1.0433, 1.0319, 1.0227, 1.0155, 1.0099, 1.0057,
    1.0027, 1.0009, 1.0001, 1.0, 1.0,
);


// The second clip takes over just after this point of the progress.
const SWAP_AT: f32 = 0.428571;
// Zoom streak taps on each side of the pixel.
const ZOOM_TAPS: i32 = 24;
// Smallest size the centre of the first clip shrinks to at full suction.
const PINCH_FLOOR: f32 = 0.25;

struct Curve { i: u32, j: u32, f: f32 }

var<private> cur: Curve;

fn f1(t: array<f32, 45>) -> f32 {
    var a = t;
    return mix(a[cur.i], a[cur.j], cur.f);
}

fn f2(t: array<vec2f, 45>) -> vec2f {
    var a = t;
    return mix(a[cur.i], a[cur.j], cur.f);
}

fn mirror(q: vec2f) -> vec2f {
    return abs((q - 1.0) - 2.0 * floor((q - 1.0) * 0.5) - 1.0);
}

fn pinch_scale(p: vec2f, amount: f32) -> f32 {
    let t = p * 0.5 + 0.5;
    let r = sin(t.x * 3.14159265) * sin(t.y * 3.14159265);
    return mix(1.0, PINCH_FLOOR, amount * r);
}

// First clip: each point p of the picture is drawn at p * pinch_scale(p), so the middle
// caves in. Find p for a given screen point by fixed-point iteration.
fn first_layer(q: vec2f, amount: f32) -> vec3f {
    let s = q * 2.0 - 1.0;
    var p = s;
    for (var k = 0; k < 10; k++) {
        p = s / pinch_scale(p, amount);
    }
    if (any(abs(p) > vec2f(1.0))) { return vec3f(0.0); }
    let uv = p * 0.5 + 0.5;
    return textureSampleLevel(first, smp, vec2f(uv.x, 1.0 - uv.y), 0.0).rgb;
}

// Second clip through a pincushion lens that relaxes to flat; outside it is black.
fn second_layer(q: vec2f, lens: vec2f) -> vec3f {
    var d = q - 0.5;
    let r = length(vec2f(d.x, d.y * globals.size.y / globals.size.x));
    d /= 1.0 + lens.x * r + lens.y * r * r;
    let uv = d + 0.5;
    if (any(uv < vec2f(0.0)) || any(uv > vec2f(1.0))) { return vec3f(0.0); }
    return textureSampleLevel(second, smp, vec2f(uv.x, 1.0 - uv.y), 0.0).rgb;
}

fn scene(q: vec2f) -> vec3f {
    if (params.progress <= SWAP_AT) { return first_layer(q, f1(PINCH)); }
    return second_layer(q, f2(LENS));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let k = clamp(params.progress, 0.0, 1.0) * 44.0;
    cur = Curve(u32(floor(k)), min(u32(floor(k)) + 1u, 44u), fract(k));
    let aspect = globals.size.y / globals.size.x;

    // Shake: the whole picture moves, scales and twists about its centre (mirrored at the edges).
    var v = vec2f(uv.x, 1.0 - uv.y) - f2(SHAKE_POS);
    v.y *= aspect;
    let a = f1(SHAKE_SPIN);
    v = vec2f(cos(a) * v.x - sin(a) * v.y, sin(a) * v.x + cos(a) * v.y);
    v.y /= aspect;
    let q = mirror(v / vec2f(f1(SHAKE_SCALE_X), f1(SHAKE_SCALE_Y)) + 0.5);

    // Zoom streaks out of the centre, both ways; taps outside the frame are skipped.
    let reach = (q - 0.5) * f1(ZOOM);
    var acc = scene(q);
    var total = 1.0;
    if (length(reach) > 0.0001) {
        for (var n = 1; n <= ZOOM_TAPS; n++) {
            for (var side = -1.0; side <= 1.0; side += 2.0) {
                let s = q + side * reach * f32(n) / f32(ZOOM_TAPS);
                if (all(s >= vec2f(0.0)) && all(s <= vec2f(1.0))) {
                    acc += scene(s);
                    total += 1.0;
                }
            }
        }
    }
    gpufx_write(id, vec4f(acc / total, 1.0));
}
