// Ripple Vibe, pass 1: cut to the second clip at the midpoint while horizontal noise ripples run down the picture.

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * x1 + 3.0 * inv * s * s * x2 + s * s * s;
        let dx = 3.0 * inv * inv * x1 + 6.0 * inv * s * (x2 - x1) + 3.0 * s * s * (1.0 - x2);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * y1 + 3.0 * inv * s * s * y2 + s * s * s;
}

// 0 -> 1 -> 0 envelope: a fast ease-out up to the midpoint, an ease-in-out back down.
fn swell(p: f32) -> f32 {
    if (p < 0.5) {
        return bezier_ease(p / 0.5, 0.33333, 0.0, 0.0, 1.0);
    }
    return 1.0 - bezier_ease(min((p - 0.5) / 0.5, 1.0), 0.33333, 0.0, 0.66667, 1.0);
}

// Size of the frame in reference pixels (short side = 1080).
fn ref_size() -> vec2f {
    return globals.size * (1080.0 / min(globals.size.x, globals.size.y));
}

const WAVELENGTH: f32 = 300.0; // reference pixels
const MAX_AMPLITUDE: f32 = 50.0; // reference pixels

// Smooth pseudo-random wave of one period position (0..1).
fn ripple_shape(q: f32) -> f32 {
    let z = 3.1415927 * q * 30.0;
    return cos(z * 0.5) * cos(z * 0.13) * sin((z + 10.0) * 0.3);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = ref_size();
    let p = gpufx_uv(id) * size;
    let amp = MAX_AMPLITUDE * swell(params.progress);
    // With `animate` off the ripple clock stays at 0, as in CapCut's export.
    let drift = select(0.0, -params.progress * params.duration, params.animate != 0u);
    let shift = ripple_shape(fract(p.y / WAVELENGTH + drift)) * amp;
    // Pin the picture at every edge, letting the ripple grow over 1.2 amplitudes inward.
    let edge = max(amp * 1.2, 1e-4);
    let fade = clamp(min(p, size - p) / edge, vec2f(0.0), vec2f(1.0));
    let q = (p + vec2f(shift, 0.0) * min(fade.x, fade.y)) / size;
    var c = vec4f(0.0);
    if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
        if (params.progress <= 0.5) {
            c = textureSampleLevel(first, smp, q, 0.0);
        } else {
            c = textureSampleLevel(second, smp, q, 0.0);
        }
    }
    gpufx_write(id, c);
}
