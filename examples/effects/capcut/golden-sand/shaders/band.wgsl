// Golden Sand, band layer: bright (upper) or dark (lower) pixels of the first clip in a moving strip, scattered by a grainy map and turbulence.

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

// Colour matrices of the warm tint at intensity 0, 0.05 .. 0.7 (rows: red, green, blue).
const WARM = array<array<f32, 9>, 15>(
    array<f32, 9>(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0),
    array<f32, 9>(1.003058, 0.004366, 0.000821, -0.000217, 0.999057, 0.000234, -0.000318, -0.001196, 0.987064),
    array<f32, 9>(1.006117, 0.008897, 0.001548, -0.000433, 0.998011, 0.000485, -0.000647, -0.002355, 0.974112),
    array<f32, 9>(1.009241, 0.013523, 0.002289, -0.000654, 0.996944, 0.000741, -0.000983, -0.003539, 0.960888),
    array<f32, 9>(1.012499, 0.018348, 0.003063, -0.000884, 0.99583, 0.001009, -0.001333, -0.004773, 0.947095),
    array<f32, 9>(1.01597, 0.023487, 0.003887, -0.001129, 0.994643, 0.001293, -0.001706, -0.006088, 0.932404),
    array<f32, 9>(1.019739, 0.029069, 0.004781, -0.001396, 0.993355, 0.001602, -0.002111, -0.007516, 0.916448),
    array<f32, 9>(1.023904, 0.035237, 0.00577, -0.00169, 0.991931, 0.001944, -0.002559, -0.009094, 0.898816),
    array<f32, 9>(1.028677, 0.042396, 0.006874, -0.002033, 0.990212, 0.002315, -0.003054, -0.010825, 0.879414),
    array<f32, 9>(1.034441, 0.051337, 0.00811, -0.002463, 0.987853, 0.0027, -0.003593, -0.012663, 0.858612),
    array<f32, 9>(1.041062, 0.061607, 0.00953, -0.002957, 0.985142, 0.003142, -0.004213, -0.014774, 0.834713),
    array<f32, 9>(1.048741, 0.073518, 0.011177, -0.00353, 0.981999, 0.003655, -0.004931, -0.017222, 0.807),
    array<f32, 9>(1.057722, 0.087448, 0.013104, -0.0042, 0.978324, 0.004255, -0.005771, -0.020085, 0.774587),
    array<f32, 9>(1.068838, 0.105168, 0.015333, -0.005056, 0.973316, 0.004894, -0.006717, -0.023221, 0.738697),
    array<f32, 9>(1.082375, 0.127003, 0.017964, -0.006113, 0.966972, 0.005616, -0.007818, -0.02682, 0.697278),
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
