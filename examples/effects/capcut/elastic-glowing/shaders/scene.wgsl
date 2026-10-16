// Elastic squash of the first clip into a fisheye flash, then the second clip springs back out
// of it; this pass draws the clips and the zoom streaks.

// Animation curves, sampled at 45 even steps of progress (y up).
const FIRST_POS = array<vec2f, 45>(
    vec2f(0.5, 0.5), vec2f(0.5, 0.50162), vec2f(0.5, 0.50596), vec2f(0.5, 0.51227),
    vec2f(0.5, 0.51978), vec2f(0.5, 0.52773), vec2f(0.5, 0.53536), vec2f(0.5, 0.5419),
    vec2f(0.5, 0.5466), vec2f(0.5, 0.54985), vec2f(0.5, 0.55257), vec2f(0.5, 0.55481),
    vec2f(0.5, 0.55662), vec2f(0.5, 0.55805), vec2f(0.5, 0.55914), vec2f(0.5, 0.55993),
    vec2f(0.5, 0.56048), vec2f(0.5, 0.56083), vec2f(0.5, 0.56102), vec2f(0.5, 0.5611),
    vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111),
    vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111),
    vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111),
    vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111),
    vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111),
    vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111), vec2f(0.5, 0.56111),
    vec2f(0.5, 0.56111),
);

const FIRST_SCALE_X = array<f32, 45>(
    1.0, 1.004, 1.016, 1.0371, 1.0682, 1.1108, 1.1665, 1.2374,
    1.326, 1.4349, 1.5653, 1.7088, 1.8, 1.6617, 1.2865, 0.7972,
    0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
    0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
    0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
    0.5, 0.5, 0.5, 0.5, 0.5,
);

const FIRST_SCALE_Y = array<f32, 45>(
    1.0, 0.99221, 0.98191, 0.96902, 0.95344, 0.93508, 0.91386, 0.88973,
    0.86273, 0.83305, 0.80135, 0.76982, 0.75, 0.86741, 0.99626, 1.0854,
    1.1443, 1.1807, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2,
    1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2,
    1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2,
    1.2, 1.2, 1.2, 1.2, 1.2,
);

const FIRST_LENS = array<vec2f, 45>(
    vec2f(0, 0), vec2f(0, 0), vec2f(0, 0), vec2f(0, 0),
    vec2f(0, 0), vec2f(0, 0), vec2f(0, 0), vec2f(0, 0),
    vec2f(0, 0), vec2f(0, 0), vec2f(0, 0), vec2f(0, 0),
    vec2f(0, 0), vec2f(0.00014179, 0.020719), vec2f(0.0060795, 0.091239), vec2f(0.043625, 0.24987),
    vec2f(0.1426, 0.5133), vec2f(0.28441, 0.8032), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296),
);

const SECOND_POS = array<vec2f, 45>(
    vec2f(0.5, 0.58796), vec2f(0.5, 0.58796), vec2f(0.5, 0.58796), vec2f(0.5, 0.58796),
    vec2f(0.5, 0.58796), vec2f(0.5, 0.58796), vec2f(0.5, 0.58796), vec2f(0.5, 0.58796),
    vec2f(0.5, 0.58796), vec2f(0.5, 0.58796), vec2f(0.5, 0.58796), vec2f(0.5, 0.58796),
    vec2f(0.5, 0.58796), vec2f(0.5, 0.58796), vec2f(0.5, 0.58796), vec2f(0.5, 0.58796),
    vec2f(0.5, 0.58796), vec2f(0.5, 0.58796), vec2f(0.5, 0.58796), vec2f(0.49978, 0.54891),
    vec2f(0.49925, 0.45421), vec2f(0.49882, 0.37751), vec2f(0.49856, 0.33196), vec2f(0.49843, 0.30842),
    vec2f(0.49838, 0.3), vec2f(0.49843, 0.30554), vec2f(0.49851, 0.31617), vec2f(0.49863, 0.33041),
    vec2f(0.49876, 0.34707), vec2f(0.49891, 0.36515), vec2f(0.49906, 0.38385), vec2f(0.49921, 0.40248),
    vec2f(0.49936, 0.42049), vec2f(0.49949, 0.43741), vec2f(0.49962, 0.45286), vec2f(0.49973, 0.46652),
    vec2f(0.49982, 0.47812), vec2f(0.4999, 0.48744), vec2f(0.49995, 0.49429), vec2f(0.49999, 0.49852),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.5, 0.5),
    vec2f(0.5, 0.5),
);

const SECOND_SCALE_X = array<f32, 45>(
    2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0,
    2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0,
    2.0, 2.0, 2.0, 1.8977, 1.7084, 1.5024, 1.3066, 1.1358,
    1.0, 0.90668, 0.85108, 0.82331, 0.81404, 0.81427, 0.81522, 0.88485,
    0.9287, 0.95489, 0.97228, 0.98416, 0.99215, 0.99721, 0.99994, 1.0008,
    1.0, 1.0, 1.0, 1.0, 1.0,
);

const SECOND_SCALE_Y = array<f32, 45>(
    2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0,
    2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0,
    2.0, 2.0, 2.0, 1.9023, 1.7196, 1.5177, 1.3221, 1.1464,
    1.0, 0.94822, 1.0173, 1.1566, 1.3163, 1.447, 1.5, 1.422,
    1.3245, 1.2403, 1.1711, 1.1158, 1.0728, 1.0408, 1.0186, 1.0053,
    1.0, 1.0, 1.0, 1.0, 1.0,
);

const SECOND_LENS = array<vec2f, 45>(
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296),
    vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.36498, 0.94296), vec2f(0.35436, 0.92538),
    vec2f(0.32556, 0.87649), vec2f(0.28441, 0.8032), vec2f(0.23694, 0.71323), vec2f(0.18835, 0.61426),
    vec2f(0.1426, 0.51331), vec2f(0.10237, 0.41624), vec2f(0.069202, 0.32748), vec2f(0.043625, 0.24987),
    vec2f(0.025302, 0.18478), vec2f(0.013243, 0.13222), vec2f(0.0060797, 0.09124), vec2f(0.002341, 0.060207),
    vec2f(0.00070123, 0.037269), vec2f(0.0001418, 0.02072), vec2f(1.4071e-05, 0.0093001), vec2f(2.4733e-07, 0.0023888),
    vec2f(5.3172e-36, 6.6307e-13), vec2f(0, 0), vec2f(0, 0), vec2f(0, 0),
    vec2f(0, 0), vec2f(0, 0), vec2f(0, 0), vec2f(0, 0),
    vec2f(0, 0),
);

const ZOOM = array<f32, 45>(
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0050917, 0.023206, 0.060987, 0.13354, 0.29325,
    0.5, 0.63999, 0.835, 0.76961, 0.66207, 0.54207, 0.4175, 0.29293,
    0.17293, 0.065388, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0,
);




// The second clip takes over at this point of the progress.
const SWAP_AT: f32 = 0.454545;
// One video frame (1/30 s) in progress units; the motion trail looks this far back.
const FRAME_STEP: f32 = 0.045455;
// Zoom streak taps; their weights fade to about 17% at the far end.
const ZOOM_TAPS: i32 = 40;
const ZOOM_FADE: f32 = 0.168;

struct Curve { i: u32, j: u32, f: f32 }

fn curve_at(t: f32) -> Curve {
    let k = clamp(t, 0.0, 1.0) * 44.0;
    let i = u32(floor(k));
    return Curve(i, min(i + 1u, 44u), k - floor(k));
}

fn f1(t: array<f32, 45>, c: Curve) -> f32 {
    var a = t;
    return mix(a[c.i], a[c.j], c.f);
}

fn f2(t: array<vec2f, 45>, c: Curve) -> vec2f {
    var a = t;
    return mix(a[c.i], a[c.j], c.f);
}

fn mirror(q: vec2f) -> vec2f {
    return abs((q - 1.0) - 2.0 * floor((q - 1.0) * 0.5) - 1.0);
}

struct Pose { pos: vec2f, scale: vec2f, lens: vec2f }

fn pose(t: f32, late: bool) -> Pose {
    let c = curve_at(t);
    if (late) {
        return Pose(f2(SECOND_POS, c), vec2f(f1(SECOND_SCALE_X, c), f1(SECOND_SCALE_Y, c)), f2(SECOND_LENS, c));
    }
    return Pose(f2(FIRST_POS, c), vec2f(f1(FIRST_SCALE_X, c), f1(FIRST_SCALE_Y, c)), f2(FIRST_LENS, c));
}

fn read_clip(late: bool, q: vec2f) -> vec3f {
    let p = mirror(vec2f(q.x, 1.0 - q.y));
    if (late) { return textureSampleLevel(second, smp, p, 0.0).rgb; }
    return textureSampleLevel(first, smp, p, 0.0).rgb;
}

// The active clip, stretched, with a two-tap motion trail and a pincushion lens (y up).
fn layer(q0: vec2f) -> vec3f {
    let t = clamp(params.progress, 0.0, 1.0);
    let late = t >= SWAP_AT;
    let now = pose(t, late);
    let before = pose(t - FRAME_STEP, late);

    var d = q0 - 0.5;
    let aspect = globals.size.y / globals.size.x;
    let r = length(vec2f(d.x, d.y * aspect));
    let f = 1.0 + now.lens.x * r + now.lens.y * r * r;
    d /= f;
    let q = d + 0.5;
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return vec3f(0.0); }

    // Trail spans 0.75 .. 0.75 + length of the way from the previous frame's pose to this one.
    let reach = select(0.24, 0.5, late);
    var acc = vec3f(0.0);
    for (var n = 0; n < 2; n++) {
        let w = 0.75 + reach * f32(n);
        let pos = mix(before.pos, now.pos, w);
        let scale = mix(before.scale, now.scale, w);
        acc += read_clip(late, (q - pos) / scale + 0.5);
    }
    return acc * 0.5;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let q = vec2f(uv.x, 1.0 - uv.y);
    let reach = (q - 0.5) * f1(ZOOM, curve_at(params.progress));
    var acc = layer(q);
    var total = 1.0;
    if (length(reach) > 0.0001) {
        for (var n = 1; n <= ZOOM_TAPS; n++) {
            let w = pow(ZOOM_FADE, f32(n) / f32(ZOOM_TAPS));
            acc += w * layer(q - reach * f32(n) / f32(ZOOM_TAPS));
            total += w;
        }
    }
    gpufx_write(id, vec4f(acc / total, 1.0));
}
