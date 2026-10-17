#!/usr/bin/env python3
"""Generates the shaders and the pass list of examples/effects/capcut/golden-sand.

The glow of that effect is seven blur rounds per band, each round with its own constants, so its
WGSL and the manifest's `passes` are written by this script instead of by hand. Edit this file,
then run it (no dependencies):  python3 scripts/make-golden-sand.py
It rewrites examples/effects/capcut/golden-sand/shaders/*.wgsl and the `passes` of its manifest.json.
"""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EFFECT = ROOT / "examples" / "effects" / "capcut" / "golden-sand"
SHADERS = EFFECT / "shaders"

GLOW_ROUNDS = 7  # the glow is read after the seventh round
FIB = [1, 1, 2, 3, 5, 8, 13, 21]
RADIUS = 360 * 5
RADIUS_SCALE = RADIUS / 500.0
STEP_DIVISOR = 1.5 * (1.0 + 1.5 * (RADIUS - 500) / 1500.0)
# Size of the coarse grid each round blurs on, as a fraction of the frame.
SHRINK = [0.05] + [0.025] * 6 + [0.05]
GAMMA = 2.0
FALLOFF = 0.05 ** (1.0 / 8.0)


def f(x):
    """A float literal for WGSL."""
    s = "%.7g" % x
    if "e" in s:
        s = "%.10f" % x
    if "." not in s:
        s += ".0"
    return s


# ---- warm tint: colour matrices that move the white point to a lower colour temperature ----

# Planckian locus table: reciprocal temperature (MK^-1), u, v, slope of the isotherm.
LOCUS = [
    0, 0.18006, 0.26352, -0.24341, 10, 0.18066, 0.26589, -0.25479, 20, 0.18133, 0.26846, -0.26876,
    30, 0.18208, 0.27119, -0.28539, 40, 0.18293, 0.27407, -0.30470, 50, 0.18388, 0.27709, -0.32675,
    60, 0.18494, 0.28021, -0.35156, 70, 0.18611, 0.28342, -0.37915, 80, 0.18740, 0.28668, -0.40955,
    90, 0.18880, 0.28997, -0.44278, 100, 0.19032, 0.29326, -0.47888, 125, 0.19462, 0.30141, -0.58204,
    150, 0.19962, 0.30921, -0.70471, 175, 0.20525, 0.31647, -0.84901, 200, 0.21142, 0.32312, -1.0182,
    225, 0.21807, 0.32909, -1.2168, 250, 0.22511, 0.33439, -1.4512, 275, 0.23247, 0.33904, -1.7298,
    300, 0.24010, 0.34308, -2.0637, 325, 0.24792, 0.34655, -2.4681, 350, 0.25591, 0.34951, -2.9641,
    375, 0.26400, 0.35200, -3.5814, 400, 0.27218, 0.35407, -4.3633, 425, 0.28039, 0.35577, -5.3762,
    450, 0.28863, 0.35714, -6.7262, 475, 0.29685, 0.35823, -8.5955, 500, 0.30505, 0.35907, -11.324,
    525, 0.31320, 0.35968, -15.628, 550, 0.32129, 0.36011, -23.325, 575, 0.32931, 0.36038, -40.770,
    600, 0.33724, 0.36051, -116.45,
]
BRADFORD = [[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]]
BRADFORD_INV = [[0.987, -0.1471, 0.16], [0.4323, 0.5184, 0.0493], [-0.0085, 0.04, 0.9685]]
RGB_TO_XYZ = [[0.4123907992659595, 0.357584339383878, 0.1804807884018343],
              [0.21263900587151036, 0.715168678767756, 0.07219231536073371],
              [0.019330818715591832, 0.11919477979462598, 0.9505321522496607]]
XYZ_TO_RGB = [[3.2409699419045213, -1.5373831775700935, -0.4986107602930033],
              [-0.9692436362808796, 1.8759675015077208, 0.04155505740717562],
              [0.05563007969699364, -0.20397695888897655, 1.0569715142428784]]


def locus(i):
    return LOCUS[i - 1]


def lerp(x, y, a):
    return x * (1 - a) + y * a


def white_xyz(kelvin, tint):
    """XYZ (Y = 1) of the white at `kelvin`, moved by `tint` along the isotherm."""
    x = 1e6 / kelvin
    y = tint * 1e-4
    index = 5
    data = locus(index)
    index += 4
    while data <= x and index < len(LOCUS) + 1:
        data = locus(index)
        index += 4
    w = (data - x) / (data - locus(index - 8))
    uv = [lerp(locus(index - 3), locus(index - 7), w), lerp(locus(index - 2), locus(index - 6), w)]
    a = locus(index - 5)
    b = locus(index - 1)
    sa = math.sqrt(a * a + 1)
    sb = math.sqrt(b * b + 1)
    d = [lerp(1 / sb, 1 / sa, w), lerp(b / sb, a / sa, w)]
    n = math.hypot(*d)
    uv = [y * d[0] / n + uv[0], y * d[1] / n + uv[1]]
    den = -4 * uv[1] + uv[0] + 2
    a = uv[0] * 1.5 / den
    b = uv[1] / den
    a = min(max(a, 1e-6), 0.999999)
    b = min(max(b, 1e-6), 0.999999)
    if a + b > 0.999999:
        s = 0.999999 / (a + b)
        a /= s
        b /= s
    return [a / b, 1, (1 - a - b) / b]


def mat_vec(m, v):
    return [sum(m[i][j] * v[j] for j in range(3)) for i in range(3)]


def mat_mul(m1, m2):
    return [[sum(m1[i][k] * m2[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def warm_matrix(amount):
    """Linear-RGB matrix of the warm tint at `amount` (0 = identity)."""
    kelvin = 6500 - 1970 * amount + 876 * amount * amount - 2630 * amount ** 3
    if kelvin == 6500:
        return [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    v = mat_vec(BRADFORD, white_xyz(kelvin, 0))
    ref = mat_vec(BRADFORD, white_xyz(6500, 0))
    scale = [[v[0] / ref[0], 0, 0], [0, v[1] / ref[1], 0], [0, 0, v[2] / ref[2]]]
    m = mat_mul(scale, BRADFORD)
    m = mat_mul(BRADFORD_INV, m)
    m = mat_mul(m, RGB_TO_XYZ)
    return mat_mul(XYZ_TO_RGB, m)


# ---- WGSL shared by every shader ----

COMMON = r"""
// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn ease(x: f32, c: vec4f) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        let dx = 3.0 * inv * inv * c.x + 6.0 * inv * s * (c.z - c.x) + 3.0 * s * s * (1.0 - c.z);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Value going from `a` to `b` between times t0 and t1 along the easing curve `c`; `v` outside.
fn key(v: f32, t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return v; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);
const SPAN: f32 = 2.0;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// At the ends the last pass shows the plain clips, so the passes before it have nothing to do.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }
"""

WARM_ROWS = "\n".join(
    "    array<f32, 9>(" + ", ".join(f(round(warm_matrix(k * 0.05)[r][c], 6)) for r in range(3) for c in range(3)) + "),"
    for k in range(15))

TINT = """
// Colour matrices of the warm tint at intensity 0, 0.05 .. 0.7 (rows: red, green, blue).
const WARM = array<array<f32, 9>, 15>(
""" + WARM_ROWS + r"""
);

fn warm(c: vec3f, amount: f32) -> vec3f {
    let x = clamp(amount / 0.05, 0.0, 13.999);
    let i = i32(floor(x));
    let w = x - f32(i);
    let a = WARM[i];
    let b = WARM[i + 1];
    var m: array<f32, 9>;
    for (var k = 0; k < 9; k++) { m[k] = mix(a[k], b[k], w); }
    return clamp(vec3f(m[0] * c.r + m[1] * c.g + m[2] * c.b,
                       m[3] * c.r + m[4] * c.g + m[5] * c.b,
                       m[6] * c.r + m[7] * c.g + m[8] * c.b), vec3f(0.0), vec3f(1.0));
}

// Brightness curve: 1 - (1 - c)^k, with a small lift removed when darkening.
fn brighten(c: vec3f, amount: f32) -> vec3f {
    var x = c;
    var k = 1.0;
    if (amount > 0.0) {
        k = 1.0 + amount * 5.0;
    } else {
        k = 1.0 / (1.0 - amount * 2.5);
        x -= vec3f(-amount * 0.01);
    }
    return clamp(1.0 - pow(max(1.0 - x, vec3f(0.0)), vec3f(k)), vec3f(0.0), vec3f(1.0));
}
"""

# ---- band layer (one entry per band) and last pass ----

BAND = r"""
const TAU: f32 = 6.2831853;

// ---- Grain used as the displacement map ----

fn grain_hash(p: vec2f, seed: f32) -> vec2f {
    var q = fract(p.xyx * vec3f(0.1031, 0.103, 0.0973));
    q += dot(q, q.yzx + 33.33 + seed);
    return fract((q.xx + q.yz) * q.zy) * 2.0 - 1.0;
}

fn grain_gradient(p: vec2f, cell: f32, seed: f32) -> f32 {
    let i = floor(p / cell);
    let f = fract(p / cell);
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let a = dot(grain_hash(i * cell, seed), f);
    let b = dot(grain_hash((i + vec2f(1.0, 0.0)) * cell, seed), f - vec2f(1.0, 0.0));
    let c = dot(grain_hash((i + vec2f(0.0, 1.0)) * cell, seed), f - vec2f(0.0, 1.0));
    let d = dot(grain_hash((i + vec2f(1.0)) * cell, seed), f - vec2f(1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fine grain in [0, 1]: two octave pairs blended by the fractional part of the size.
fn grain(p: vec2f, size: f32, seed: f32) -> f32 {
    let n = 2.0 / max(0.1, size);
    let lo = exp2(floor(n));
    let hi = exp2(floor(n) + 1.0);
    let a = 0.6 * (grain_gradient(p * 500.0, 500.0 / lo, seed) * 0.5 + 0.5)
          + 0.4 * (grain_gradient(p * 300.0, 300.0 / lo, seed) * 0.5 + 0.5);
    let b = 0.6 * (grain_gradient(p * 500.0, 500.0 / hi, seed) * 0.5 + 0.5)
          + 0.4 * (grain_gradient(p * 300.0, 300.0 / hi, seed) * 0.5 + 0.5);
    return mix(a, b, fract(n));
}

fn overlay1(base: f32, top: f32) -> f32 {
    if (base < 0.5) { return 2.0 * base * top; }
    return 1.0 - 2.0 * (1.0 - base) * (1.0 - top);
}

// Radial ramp: black in the middle, lighter toward the corners.
fn ramp(uv: vec2f) -> f32 {
    let d = length((uv - 0.5) * vec2f(816.0, 1088.0) / vec2f(810.0, 1080.0)) * 400.0;
    return clamp((d - 33.0) * 0.00497, 0.0, 1.0);
}

// Red channel of the map: the first clip, darkened, with grain and the radial ramp laid over it.
fn map_value(uv: vec2f, t: f32) -> f32 {
    let stops = key(key(-3.0, t, 0.0, 1.333333, -3.0, -4.333333, LINEAR), t, 1.333333, 2.0, -4.333333, -5.833333, vec4f(0.25, 0.09, 0.75, 0.96));
    let src = textureSampleLevel(first, smp, uv, 0.0).r;
    let dark = clamp(src * exp2(stops / 2.2), 0.0, 1.0);
    // Grain is laid out with y up and x stretched by the aspect ratio.
    let gp = vec2f(uv.x * globals.size.x / globals.size.y, 1.0 - uv.y);
    let contrast = 4.0;
    let gr = (grain(gp, 0.21, 0.0) - 0.5) * contrast + 0.5;
    let gg = (grain(gp, 0.21, 2.0) - 0.5) * contrast + 0.5;
    let gb = (grain(gp, 0.21, 4.0) - 0.5) * contrast + 0.5;
    let tinted = gr * (1.0 - 0.0357498 - 0.2808393) + gg * 0.2808393 + gb * 0.0357498;
    let grainy = clamp(overlay1(dark, tinted), 0.0, 1.0);
    let opacity = key(40.0, t, 0.0, 1.333333, 40.0, 88.0, LINEAR) / 100.0;
    return clamp(mix(grainy, overlay1(grainy, ramp(uv)), opacity), 0.0, 1.0);
}

// ---- Turbulent displacement (gradient noise whose gradients turn with `evolve`) ----

fn cell_seed(c: vec2f) -> f32 {
    let f = fract(c * 1324.5179);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

fn cell_pair(c: vec2f, k: f32, seed: f32) -> vec2f {
    let f = fract(c * k);
    let g = f + vec2f(dot(f, f.yx + vec2f(15.434)));
    return fract((g + g.yx + vec2f(0.523)) * g.yx + vec2f(seed));
}

const LOOP_STEPS: f32 = 300.0;

fn cell_gradient(c: vec2f, evolve: f32, layer: f32) -> vec2f {
    let seed = cell_seed(c);
    let turn = evolve * 0.25 + seed;
    let ta = floor(turn % LOOP_STEPS);
    let tb = floor((turn + 1.0) % LOOP_STEPS);
    let ka = cell_pair(c, 34.532 + ta * 2.0 + layer * 0.8031, seed);
    var kb = cell_pair(c, 34.532 + tb * 2.0 + layer * 0.8031, seed);
    kb.y += 1.0;
    let angle = mix(ka.y, kb.y, fract(turn)) * TAU;
    let grow = evolve * 2.0 + seed;
    let ga = floor(grow % LOOP_STEPS);
    let gb = floor((grow + 1.0) % LOOP_STEPS);
    let ma = cell_pair(c, 34.532 + ga * 2.0 + layer * 0.8031, seed);
    let mb = cell_pair(c, 34.532 + gb * 2.0 + layer * 0.8031, seed);
    return vec2f(cos(angle), sin(angle)) * mix(0.75, 1.0, mix(ma.x, mb.x, fract(grow)));
}

fn gradient_noise(p: vec2f, evolve: f32, layer: f32, cells: vec2f) -> f32 {
    let g = p * cells / 100.0;
    let i = floor(g);
    let f = fract(g);
    let s = smoothstep(vec2f(0.0), vec2f(1.0), f);
    let n00 = dot(cell_gradient(i, evolve, layer), f);
    let n10 = dot(cell_gradient(i + vec2f(1.0, 0.0), evolve, layer), f - vec2f(1.0, 0.0));
    let n01 = dot(cell_gradient(i + vec2f(0.0, 1.0), evolve, layer), f - vec2f(0.0, 1.0));
    let n11 = dot(cell_gradient(i + vec2f(1.0), evolve, layer), f - vec2f(1.0));
    return mix(mix(n00, n10, s.x), mix(n01, n11, s.x), s.y) * 0.5 + 0.5;
}

// Fractal sum of `detail` octaves (the fractional part fades the last one in), each 1.79x finer, 0.6x weaker.
fn turbulence(p0: vec2f, detail: f32, evolve: f32, layer: f32, cells: vec2f) -> f32 {
    var p = p0;
    let whole = floor(detail);
    var total = 1.0;
    var weight = 0.6;
    var acc = gradient_noise(p, evolve, 1.0 + layer, cells);
    for (var o = 2.0; o <= 10.0; o += 1.0) {
        if (o > whole) { break; }
        p *= 100.0 / 56.0;
        total += weight;
        acc += gradient_noise(p, evolve, 1.0 + layer, cells) * weight;
        weight *= 0.6;
    }
    p *= 100.0 / 56.0;
    let part = fract(detail);
    total += weight * part;
    acc += gradient_noise(p, evolve, 1.0 + layer, cells) * weight * part;
    return clamp(acc / total, 0.0, 1.0);
}

fn mirror01(q: vec2f) -> vec2f {
    return abs((q - 1.0) - 2.0 * floor((q - 1.0) / 2.0) - 1.0);
}

// Where the turbulence makes pixel `uv` read from.
fn churn(uv: vec2f, size: f32, evolve: f32, drift: vec2f) -> vec2f {
    if (size <= 0.0) { return uv; }
    let up = vec2f(uv.x, 1.0 - uv.y);
    let cells = vec2f(720.0) * globals.size / min(globals.size.x, globals.size.y);
    let p = (up - drift) / 3.5 - vec2f(10.0);
    let nx = turbulence(p, 10.0, evolve, 2.11, cells);
    let ny = turbulence(p, 10.0, evolve, 9.71, cells);
    let span = min(globals.size.x, globals.size.y);
    let push = (vec2f(nx, ny) - 0.5) * size * 10.0 * span / globals.size * 0.3;
    return mirror01(uv + push * vec2f(1.0, -1.0));
}

// ---- The band layer ----

fn luma(c: vec3f) -> f32 { return dot(c, vec3f(0.3, 0.5882353, 0.1117647)); }

// Horizontal strip of the frame: centre and half height as fractions of the height.
fn strip(y: f32, centre: f32, half: f32) -> f32 {
    return clamp((half - abs(y - centre)) * globals.size.y + 0.5, 0.0, 1.0);
}

struct BandShape {
    low: f32,      // luma floor of the kept pixels (0..1)
    high: f32,     // luma ceiling of the kept pixels (0..1)
    centre: f32,
    half: f32,
    opacity: f32,
    push: f32,     // vertical map strength
    size: f32,     // turbulence size
    drift: vec2f,
};

// Pixels of the first clip inside the luma range and the strip, shifted by the map, then churned.
fn band_layer(uv: vec2f, t: f32, s: BandShape) -> vec4f {
    let q = churn(uv, s.size, t * 2.0, s.drift);
    let shift = (map_value(q, t) - 0.5) * 2.0 * s.push * globals.size.x / globals.size.y;
    let r = vec2f(q.x, q.y - shift);
    if (r.y < 0.0 || r.y > 1.0) { return vec4f(0.0); }
    let c = textureSampleLevel(first, smp, r, 0.0).rgb;
    let l = luma(c);
    let keep = clamp((l - s.low) / 1e-5, 0.0, 1.0) * (1.0 - clamp((l - s.high) / 1e-5, 0.0, 1.0));
    let a = keep * strip(r.y, s.centre, s.half) * s.opacity;
    return vec4f(c * a, a);
}

@compute @workgroup_size(8, 8)
fn upper(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let t = clock();
    var s: BandShape;
    s.low = key(key(210.0, t, 0.0, 0.833333, 210.0, 185.0, vec4f(0.333333, 0.0, 0.666667, 1.0)), t, 0.833333, 2.0, 185.0, 255.0, vec4f(0.333333, 0.0, 0.748105, 0.982464)) / 255.0;
    s.high = 1.0;
    var y = key(145.8, t, 0.0, 1.233333, 145.8, 349.363905, vec4f(0.25, 0.0, 0.71, 0.5));
    y = key(y, t, 1.233333, 1.633333, 349.363905, 481.21498, vec4f(0.384707, 0.337013, 0.833333, 0.741397));
    y = key(y, t, 1.633333, 2.0, 481.21498, 741.480209, vec4f(0.52, 0.28, 0.999, 1.0));
    s.centre = y / 1080.0;
    s.half = 0.5 * key(27.0, t, 1.233333, 2.0, 27.0, 12.0, vec4f(0.241879, 0.0, 0.784387, 1.0)) / 100.0;
    s.opacity = 1.0;
    s.push = -t / 2.0;
    s.size = key(0.0, t, 0.0, 0.833333, 0.0, 0.27, vec4f(0.343435, 0.0, 0.696603, 1.0));
    s.drift = vec2f(0.0, 0.02);
    gpufx_write(id, band_layer(gpufx_uv(id), t, s));
}

@compute @workgroup_size(8, 8)
fn lower(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let t = clock();
    var s: BandShape;
    s.low = 0.0;
    var w = key(238.0, t, 0.366667, 0.866667, 238.0, 198.0, vec4f(0.338147, 0.0, 0.716452, 1.0));
    w = key(w, t, 0.866667, 1.366667, 198.0, 238.0, vec4f(0.290506, 0.0, 0.648484, 1.0));
    w = key(w, t, 1.366667, 2.0, 238.0, 0.0, vec4f(0.460275, 0.0, 0.689163, 1.0));
    s.high = w / 255.0;
    var y = key(145.8, t, 0.0, 1.233333, 145.8, 349.363905, vec4f(0.357287, 0.0, 0.714254, 0.500082));
    y = key(y, t, 1.233333, 1.633333, 349.363905, 481.21498, vec4f(0.384707, 0.337013, 0.724899, 0.739747));
    y = key(y, t, 1.633333, 2.0, 481.21498, 950.0, vec4f(0.46, 0.161333, 0.999, 1.0));
    s.centre = y / 1080.0;
    var h = key(27.0, t, 0.0, 0.833333, 27.0, 38.0, vec4f(0.567807, 0.0, 0.733119, 1.0));
    h = key(h, t, 0.833333, 1.233333, 38.0, 28.0, vec4f(0.443945, 0.0, 0.794737, 0.333831));
    h = key(h, t, 1.233333, 2.0, 28.0, 14.0, vec4f(0.162282, 0.721048, 0.620184, 1.0));
    s.half = 0.5 * h / 100.0;
    s.opacity = key(100.0, t, 1.366667, 2.0, 100.0, 0.0, vec4f(0.333333, 0.0, 0.666667, 1.0)) / 100.0;
    s.push = -key(0.0, t, 0.0, 2.0, 0.0, 1.0, vec4f(0.370249, 0.0, 0.794033, 1.0));
    s.size = key(0.0, t, 0.0, 0.6, 0.0, 0.16, vec4f(0.343435, 0.0, 0.696603, 1.0));
    s.drift = vec2f(0.0);
    gpufx_write(id, band_layer(gpufx_uv(id), t, s));
}
"""

FINISH = r"""
// First clip after the wipe that clears it from the top down (premultiplied by the wipe).
fn wiped_first(uv: vec2f, edge: f32, feather: f32) -> vec4f {
    let a = smoothstep(edge - feather, edge + feather, uv.y);
    let c = textureSampleLevel(first, smp, clamp(uv, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
    return vec4f(c * a, a);
}

// The wiped first clip under a light gaussian blur (one tap each side per axis, in gamma 2.2).
fn soft_first(uv: vec2f, t: f32) -> vec4f {
    var edge = key(0.0, t, 0.0, 0.766667, 0.0, 0.47, vec4f(0.021036, 0.795328, 0.341175, 0.662657));
    edge = key(edge, t, 0.766667, 2.0, 0.47, 1.0, vec4f(0.444731, 0.358012, 0.961445, 0.556363));
    edge = edge * 2.0 - 0.5;
    let feather = key(0.04, t, 0.0, 1.666667, 0.04, 0.25, vec4f(0.5, 0.0, 0.82, 1.0));
    let strength = key(0.0, t, 0.333333, 1.366667, 0.0, 25.0, vec4f(0.2, 0.0, 0.8, 1.0));
    var taps = (0.5 * strength + 2.0) * 0.78;
    if (taps < 2.0) { taps = floor(taps + 0.5); }
    taps *= 0.1584893;
    if (taps < 1.0 || strength <= 0.01) {
        return wiped_first(uv, edge, feather);
    }
    let base = max(min(globals.size.x, globals.size.y), max(globals.size.x, globals.size.y) * 0.5);
    let radius = base / globals.size * strength / 1000.0;
    let d = radius / taps;
    let x = 2.5 / taps;
    let w = exp(-0.5 * x * x);
    var sum = vec4f(0.0);
    var total = 0.0;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let wt = select(1.0, w, i != 0) * select(1.0, w, j != 0);
            let s = wiped_first(uv + vec2f(f32(i), f32(j)) * d, edge, feather);
            sum += vec4f(pow(s.rgb, vec3f(2.2)), s.a) * wt;
            total += wt;
        }
    }
    let m = sum / total;
    return vec4f(pow(m.rgb, vec3f(1.0 / 2.2)), m.a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clock();

    // Outgoing clip (wiped, blurred, darkened) over the incoming clip (darkened, recovering).
    let fa = soft_first(uv, t);
    let a_rgb = brighten(fa.rgb, key(0.0, t, 0.0, 1.366667, 0.0, -0.67, vec4f(0.254178, 0.0, 0.72872, 1.0)));
    let b_rgb = brighten(textureSampleLevel(second, smp, uv, 0.0).rgb, key(-0.55, t, 0.0, 1.766667, -0.55, 0.0, vec4f(0.271280, 0.0, 0.745822, 1.0)));
    var c = a_rgb + b_rgb * (1.0 - fa.a);

    // Lower glowing band, warmed.
    let g2 = textureSampleLevel(glow_lower, smp, uv, 0.0);
    let warm2 = warm(g2.rgb, key(0.0, t, 0.1, 0.666667, 0.0, 0.66, vec4f(0.2, 0.0, 0.8, 1.0)));
    c = warm2 + c * (1.0 - g2.a);

    // Upper glowing band, brightened.
    let g1 = textureSampleLevel(glow_upper, smp, uv, 0.0);
    let lit1 = brighten(g1.rgb, key(0.0, t, 0.1, 0.666667, 0.0, 0.55, vec4f(0.2, 0.0, 0.8, 1.0)));
    c = lit1 + c * (1.0 - g1.a);

    var tint = key(0.0, t, 0.0, 0.666667, 0.0, 0.17, vec4f(0.333333, 0.0, 0.666667, 1.0));
    tint = key(tint, t, 1.333333, 2.0, 0.17, 0.0, vec4f(0.333333, 0.0, 0.666667, 1.0));
    gpufx_write(id, vec4f(warm(clamp(c, vec3f(0.0), vec3f(1.0)), tint), 1.0));
}
"""

# ---- glow ----
#
# Each round blurs along x then y on a coarse grid (SHRINK of the frame), then screens the blur over the
# round's input at full size. The blur passes only run on the texels of their grid, which they store in the
# top-left corner of their output; the passes after them read that corner back with bilinear filtering.

LOWRES = r"""
fn grid(shrink: f32) -> vec2f {
    return max(floor(globals.size * shrink), vec2f(1.0));
}

// Texel `j` of the coarse grid `cells`, as a uv of the full-size texture it is read from.
fn cell_uv(cells: vec2f, j: vec2f) -> vec2f {
    return (clamp(j, vec2f(0.0), cells - 1.0) + 0.5) / cells;
}

// Point `p` (in texels) of a coarse grid stored in the top-left corner of a texture, as a uv of that texture.
fn corner_uv(cells: vec2f, p: vec2f) -> vec2f {
    return clamp(p, vec2f(0.5), cells - 0.5) / globals.size;
}
"""


def sample_cells(name):
    """Reads a full-size texture as if it held only the centres of a coarse grid (bilinear, clamped edges)."""
    return f"""
// Bilinear read of `{name}` sampled at the centres of the coarse grid `cells` (clamped edges).
fn cells_{name}(uv: vec2f, cells: vec2f) -> vec4f {{
    let p = uv * cells - 0.5;
    let j = floor(p);
    let w = p - j;
    let a = textureSampleLevel({name}, smp, cell_uv(cells, j), 0.0);
    let b = textureSampleLevel({name}, smp, cell_uv(cells, j + vec2f(1.0, 0.0)), 0.0);
    let c = textureSampleLevel({name}, smp, cell_uv(cells, j + vec2f(0.0, 1.0)), 0.0);
    let d = textureSampleLevel({name}, smp, cell_uv(cells, j + vec2f(1.0)), 0.0);
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}}
"""


def sample_corner(name):
    """Reads a coarse grid stored in the top-left corner of a texture: one filtered fetch."""
    return f"""
// Bilinear read of the coarse grid `cells` stored in the top-left corner of `{name}` (clamped edges).
fn corner_{name}(uv: vec2f, cells: vec2f) -> vec4f {{
    return textureSampleLevel({name}, smp, corner_uv(cells, uv * cells), 0.0);
}}
"""


# Glow exposure of each band over the clock t.
EXPOSURE = {
    "upper": "key(key(key(0.0, t, 0.0, 0.666667, 0.0, 0.9, vec4f(0.2, 0.0, 0.8, 1.0)), t, 0.666667, 1.133333, 0.9, 0.9, LINEAR), t, 1.133333, 2.0, 0.9, 0.5, vec4f(0.422435, 0.0, 0.772559, 1.0))",
    "lower": "key(key(key(0.0, t, 0.0, 0.666667, 0.0, 0.84, vec4f(0.2, 0.0, 0.8, 1.0)), t, 0.666667, 1.133333, 0.84, 0.84, LINEAR), t, 1.133333, 2.0, 0.84, 1.04, vec4f(0.511348, 0.0, 0.988462, 1.0))",
}

THRESHOLD = r"""
// Bright-pass of the band layer: channels under the threshold drop out, the rest goes to gamma space.
fn bright_pass(c: vec4f) -> vec4f {
    let keep = select(vec3f(0.0), c.rgb, c.rgb >= vec3f(GLOW_THRESHOLD));
    return pow(vec4f(keep, c.a), vec4f(GLOW_GAMMA));
}
"""

GLOW_HEAD = f"""
const GLOW_GAMMA: f32 = {f(GAMMA)};
const GLOW_THRESHOLD: f32 = 0.22;
const GAUSS0: f32 = 1.0;
"""


def round_consts(i):
    steps = min(RADIUS_SCALE * FIB[i - 1], i * RADIUS_SCALE, i * 6)
    taps = int(steps)  # k runs 1 .. taps-1
    stride = RADIUS_SCALE * i / STEP_DIVISOR
    return steps, taps, stride


def blur_entry(i, axis, read):
    """Gaussian blur of round i along `axis`; `read(uv)` is the WGSL that reads the round's input."""
    steps, taps, stride = round_consts(i)
    d = "vec2f(1.0, 0.0)" if axis == "x" else "vec2f(0.0, 1.0)"
    out = f"""
@compute @workgroup_size(8, 8)
fn blur_{axis}_{i}(@builtin(global_invocation_id) id: vec3u) {{
    if (!gpufx_in_bounds(id) || idle()) {{ return; }}
    let cells = grid({f(SHRINK[i - 1])});
    // Only the texels of the coarse grid are worked out; they fill the top-left corner.
    if (f32(id.x) >= cells.x || f32(id.y) >= cells.y) {{ return; }}
    let uv = (vec2f(id.xy) + 0.5) / cells;
    let longest = max(globals.size.x, globals.size.y);
    // One step along the axis, in uv, scaled so a step is the same length in x and y.
    let step = {d} * longest / globals.size * {f(stride)} / longest;
    var sum = pow({read('uv')}, vec3f(GLOW_GAMMA)) * GAUSS0;
    var total = GAUSS0;
"""
    if taps > 1:
        out += f"""    for (var k = 1; k < {taps}; k++) {{
        let x = f32(k) / {f(steps)} * 15.0;
        let w = exp(-x * x / 32.0);
        let o = step * f32(k);
        sum += (pow({read('uv + o')}, vec3f(GLOW_GAMMA)) + pow({read('uv - o')}, vec3f(GLOW_GAMMA))) * w;
        total += 2.0 * w;
    }}
"""
    out += """    gpufx_write(id, vec4f(pow(sum / total, vec3f(1.0 / GLOW_GAMMA)), 1.0));
}
"""
    return out


MERGE = r"""
fn screen3(a: vec3f, b: vec3f) -> vec3f { return 1.0 - (1.0 - a) * (1.0 - b); }

// Lays the blurred copy over the round's input with a screen blend, then applies the exposure.
fn merge(src: vec4f, halo: vec3f, weight: f32, gain: f32) -> vec4f {
    let a = vec4f(pow(src.rgb, vec3f(GLOW_GAMMA)), src.a);
    let b = vec4f(pow(halo, vec3f(GLOW_GAMMA)), 1.0);
    let ua = a.rgb / max(a.a, 0.001);
    let ub = b.rgb / max(a.a, 0.001);
    let lit = screen3(ua, ub) * weight + ua * (1.0 - weight);
    let rgb = a.rgb * (1.0 - b.a) + b.rgb * (1.0 - a.a) + lit * (a.a * b.a);
    let alpha = a.a + b.a * (1.0 - a.a);
    let o = vec4f(rgb, alpha) * gain;
    return clamp(vec4f(pow(max(o.rgb, vec3f(0.0)), vec3f(1.0 / GLOW_GAMMA)), o.a), vec4f(0.0), vec4f(1.0));
}
"""


def merge_entry(i, band, read_src):
    weight = GAMMA / i * FALLOFF
    return f"""
@compute @workgroup_size(8, 8)
fn comp_{i}_{band}(@builtin(global_invocation_id) id: vec3u) {{
    if (!gpufx_in_bounds(id) || idle()) {{ return; }}
    let uv = gpufx_uv(id);
    let t = clock();
    let gain = {EXPOSURE[band]};
    let halo = corner_g_y(uv, grid({f(SHRINK[i - 1])})).rgb;
    gpufx_write(id, merge({read_src}, halo, {f(weight)}, gain));
}}
"""


POST = r"""
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    let src = textureSampleLevel(band, smp, uv, 0.0);
    let halo = textureSampleLevel(g_b, smp, uv, 0.0).rgb;
    let peak = max(max(halo.r, halo.g), halo.b);
    let rgb = 1.0 - (1.0 - src.rgb) * (1.0 - halo);
    gpufx_write(id, vec4f(rgb, src.a + peak - src.a * peak));
}
"""


def write(name, header, body):
    with open(SHADERS / name, "w", newline="\n", encoding="utf-8") as fh:
        fh.write(header + "\n" + body)


def main():
    SHADERS.mkdir(parents=True, exist_ok=True)
    write("band.wgsl", "// Golden Sand, band layer: bright (upper) or dark (lower) pixels of the first clip in a moving strip, scattered by a grainy map and turbulence.",
          COMMON + TINT + BAND)
    write("finish.wgsl", "// Golden Sand, last pass: the wiped first clip over the second, then the two glowing bands and a warm tint.",
          COMMON + TINT + FINISH)

    # Blur along x: round 1 reads the bright-passed band, later rounds the previous round (g_a / g_b).
    body = COMMON + LOWRES + GLOW_HEAD + THRESHOLD + sample_cells("band")
    body += blur_entry(1, "x", lambda e: f"bright_pass(cells_band({e}, cells)).rgb")
    write("glow-x-first.wgsl", "// Golden Sand glow, round 1: blur the bright-passed band along x on a coarse grid.", body)
    for name, rounds in (("g_b", [2, 4, 6]), ("g_a", [3, 5, 7])):
        body = COMMON + LOWRES + GLOW_HEAD + sample_cells(name)
        for i in rounds:
            body += blur_entry(i, "x", lambda e, n=name: f"cells_{n}({e}, cells).rgb")
        write(f"glow-x-{name[-1]}.wgsl", "// Golden Sand glow: blur the previous round along x on a coarse grid.", body)

    body = COMMON + LOWRES + GLOW_HEAD + sample_corner("g_x")
    for i in range(1, GLOW_ROUNDS + 1):
        body += blur_entry(i, "y", lambda e: f"corner_g_x({e}, cells).rgb")
    write("glow-y.wgsl", "// Golden Sand glow: second blur direction (y) of each round, on the same coarse grid.", body)

    body = COMMON + LOWRES + GLOW_HEAD + THRESHOLD + MERGE + sample_corner("g_y")
    for band in ("upper", "lower"):
        body += merge_entry(1, band, "bright_pass(textureSampleLevel(band, smp, uv, 0.0))")
    write("glow-comp-first.wgsl", "// Golden Sand glow, round 1: screen the blur over the bright-passed band.", body)
    for name, rounds in (("g_a", [2, 4, 6]), ("g_b", [3, 5, 7])):
        src = "g_b" if name == "g_a" else "g_a"
        body = COMMON + LOWRES + GLOW_HEAD + MERGE + sample_corner("g_y")
        for band in ("upper", "lower"):
            for i in rounds:
                body += merge_entry(i, band, f"textureSampleLevel({src}, smp, uv, 0.0)")
        write(f"glow-comp-{src[-1]}.wgsl", "// Golden Sand glow: screen each round's blur over the previous round.", body)

    write("glow-post.wgsl", "// Golden Sand glow, last step: screen the glow over the band layer.",
          "\nfn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }\n" + POST)

    # Pass list. Every texture name is written by several passes: a pass always reads what the latest
    # pass that wrote that name left there.
    passes = []
    for band in ("upper", "lower"):
        passes.append({"shader": "shaders/band.wgsl", "entry": band, "inputs": ["first"], "output": "band"})
        for i in range(1, GLOW_ROUNDS + 1):
            if i == 1:
                passes.append({"shader": "shaders/glow-x-first.wgsl", "entry": "blur_x_1", "inputs": ["band"], "output": "g_x"})
            else:
                src = "g_b" if i % 2 == 0 else "g_a"
                passes.append({"shader": f"shaders/glow-x-{src[-1]}.wgsl", "entry": f"blur_x_{i}", "inputs": [src], "output": "g_x"})
            passes.append({"shader": "shaders/glow-y.wgsl", "entry": f"blur_y_{i}", "inputs": ["g_x"], "output": "g_y"})
            if i == 1:
                passes.append({"shader": "shaders/glow-comp-first.wgsl", "entry": f"comp_1_{band}", "inputs": ["band", "g_y"], "output": "g_b"})
            else:
                src = "g_b" if i % 2 == 0 else "g_a"
                dst = "g_a" if i % 2 == 0 else "g_b"
                passes.append({"shader": f"shaders/glow-comp-{src[-1]}.wgsl", "entry": f"comp_{i}_{band}", "inputs": [src, "g_y"], "output": dst})
        passes.append({"shader": "shaders/glow-post.wgsl", "inputs": ["band", "g_b"], "output": "glow_" + band})
    passes.append({"shader": "shaders/finish.wgsl", "inputs": ["first", "second", "glow_upper", "glow_lower"]})

    path = EFFECT / "manifest.json"
    manifest = json.loads(path.read_text(encoding="utf-8"))
    manifest["passes"] = passes
    with open(path, "w", newline="\n", encoding="utf-8") as fh:
        fh.write(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"{len(passes)} passes written to {EFFECT}")


if __name__ == "__main__":
    main()
