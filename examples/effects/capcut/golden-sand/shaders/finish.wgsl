// Golden Sand, last pass: the wiped first clip over the second, then the two glowing bands and a warm tint.

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
