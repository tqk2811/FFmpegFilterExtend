// The first clip whips left under a horizontal blur, then the second swings in around the bottom centre with a spring.

// Local timeline (seconds) the progress range 0..1 is stretched over.
const T_START: f32 = 0.533333;
const T_END: f32 = 1.666667;
// The outgoing clip leaves and the incoming one appears at this time.
const T_SWAP: f32 = 0.933333;
// The spring curve of the incoming clip is sampled once per 1/30 s from T_SWAP.
const SPRING_STEP: f32 = 0.0333333;
const PI: f32 = 3.14159265;

// Rotation (degrees, clockwise) of the incoming clip at each spring sample.
const SPRING = array<f32, 23>(
    96.0, 7.753326, -6.384515, -12.101694, -14.461336, -15.0, -13.849888, -9.722027,
    -3.439672, 0.343109, 1.325006, 1.126133, 0.254125, -0.505224, -0.710825, -0.642254,
    -0.307682, 0.060355, 0.173354, 0.115021, 0.043677, 0.016669, 0.0
);

// Evaluates a CSS-style cubic bezier timing curve (control points (ax, ay), (bx, by)) at x.
fn timing_curve(ax: f32, ay: f32, bx: f32, by: f32, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    var s = x;
    for (var i = 0; i < 24; i++) {
        s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let cx = 3.0 * inv * inv * s * ax + 3.0 * inv * s * s * bx + s * s * s;
        if (cx < x) { lo = s; } else { hi = s; }
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * ay + 3.0 * inv * s * s * by + s * s * s;
}

// Folds a coordinate into [0, len] by mirroring at every border.
fn fold(v: f32, len: f32) -> f32 {
    let m = abs(v) / len;
    let f = m - 2.0 * floor(m * 0.5);
    return select(f, 2.0 - f, f > 1.0) * len;
}

fn fold2(p: vec2f, size: vec2f) -> vec2f {
    return vec2f(fold(p.x, size.x), fold(p.y, size.y));
}

// Outgoing clip: shifted left (mirror tiled) and smeared horizontally.
fn outgoing(px: vec2f, t: f32) -> vec3f {
    let size = globals.size;
    let k = clamp((t - T_START) / (T_SWAP - T_START), 0.0, 1.0);
    let travel = timing_curve(1.0, 0.000079, 0.972727, 0.583102, k) * (-2413.0 / 1280.0) * size.x;
    let taps = floor(timing_curve(1.0, -0.001733, 0.89851, 1.00048, k) * 100.0);
    let src = fold2(px - vec2f(travel, 0.0), size);
    let stride = min(size.x, size.y) / 720.0;
    let centre_w = 0.099735;
    var acc = textureSampleLevel(first, smp, src / size, 0.0).rgb * centre_w;
    var total = centre_w;
    for (var i = 1.0; i <= taps; i += 1.0) {
        let r = i / taps;
        let w = exp(-7.03125 * r * r) * centre_w;
        let off = vec2f(i * stride, 0.0);
        let a = clamp(src + off, vec2f(0.0), size) / size;
        let b = clamp(src - off, vec2f(0.0), size) / size;
        acc += (textureSampleLevel(first, smp, a, 0.0).rgb + textureSampleLevel(first, smp, b, 0.0).rgb) * w;
        total += 2.0 * w;
    }
    return acc / total;
}

// Rotates the incoming clip by `deg` degrees clockwise around the bottom centre (mirror tiled).
fn dial_sample(px: vec2f, deg: f32) -> vec3f {
    let size = globals.size;
    let pivot = vec2f(0.5 * size.x, size.y);
    let a = -deg * PI / 180.0;
    let d = px - pivot;
    let c = cos(a);
    let s = sin(a);
    let q = pivot + vec2f(c * d.x - s * d.y, s * d.x + c * d.y);
    return textureSampleLevel(second, smp, fold2(q, size) / size, 0.0).rgb;
}

// Strength of the rotational blur trail (fraction of a full turn).
fn trail_amount(t: f32) -> f32 {
    let t1 = 0.966667;
    if (t < t1) {
        let k = clamp((t - T_SWAP) / (t1 - T_SWAP), 0.0, 1.0);
        return mix(-5.0, 3.0, timing_curve(0.333333, 0.0, 0.9999, 1.0, k)) / 200.0;
    }
    let k = clamp((t - t1) / (1.4 - t1), 0.0, 1.0);
    return mix(3.0, 0.0, timing_curve(0.0001, -0.000023, 0.17993, 0.951894, k)) / 200.0;
}

fn incoming(px: vec2f, t: f32) -> vec3f {
    let f = clamp((t - T_SWAP) / SPRING_STEP, 0.0, 22.0);
    let i = u32(floor(f));
    let j = min(i + 1u, 22u);
    let deg = mix(SPRING[i], SPRING[j], f - floor(f));
    let arc = trail_amount(t) * 360.0;
    if (abs(arc) < 0.01) { return dial_sample(px, deg); }
    // Trail of samples rotated further around the pivot; weights fade to about 17%.
    let n = 40.0;
    var acc = dial_sample(px, deg);
    var total = 1.0;
    for (var k = 1.0; k <= n; k += 1.0) {
        let w = pow(0.168, k / n);
        acc += dial_sample(px, deg - arc * k / n) * w;
        total += w;
    }
    return acc / total;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let px = uv * globals.size;
    let t = mix(T_START, T_END, clamp(params.progress, 0.0, 1.0));
    var color: vec3f;
    if (t < T_SWAP) {
        color = outgoing(px, t);
    } else {
        color = incoming(px, t);
    }
    gpufx_write(id, vec4f(color, 1.0));
}
