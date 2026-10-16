// Ripple Vibe, pass 2: camera shake with a short motion blur, and an exposure flash peaking at the midpoint.

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

const SHAKE_AMP: f32 = 96.0; // reference pixels
const SHAKE_RATE: f32 = 16.0;

// Shake offset (reference pixels) at time t seconds: three detuned sines per axis.
fn shake_offset(t: f32) -> vec2f {
    let x = 3.1415927 * t * SHAKE_RATE;
    let dx = cos(x) * 0.25 + sin(x * 1.5) * 0.16 + cos(x * 2.5) * 0.09;
    let dy = sin(x) * 0.25 + cos(x * 1.5) * 0.16 + sin(x * 2.5) * 0.09;
    let sx = select(1.0, -1.0, params.animate != 0u);
    return vec2f(sx * dx, -dy) * SHAKE_AMP;
}

fn mirror(v: f32) -> f32 {
    return abs((v + 1.0) - 2.0 * floor((v + 1.0) * 0.5) - 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends of the transition.
    if (params.progress <= 0.0) {
        gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0));
        return;
    }
    if (params.progress >= 1.0) {
        gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0));
        return;
    }
    let size = ref_size();
    let live = params.animate != 0u;
    // With `animate` off the shake clock stays at 0, as in CapCut's export.
    let t = select(0.0, params.progress * params.duration, live);
    // Motion blur over a 1/15 s shutter (1/60 s when frozen), one tap per 10 reference pixels of travel.
    let half = select(1.0 / 120.0, 1.0 / 30.0, live);
    let a = shake_offset(t - half);
    let b = shake_offset(t + half);
    let taps = clamp(ceil(length(b - a) / 10.0), 1.0, 8.0);
    var sum = vec4f(0.0);
    for (var k = 0; k < 8; k++) {
        if (f32(k) >= taps) { break; }
        let q = uv + mix(a, b, f32(k) / taps) / size;
        sum += textureSampleLevel(rippled, smp, vec2f(mirror(q.x), mirror(q.y)), 0.0);
    }
    let c = sum / taps;
    // Exposure in stops, applied in linear light (gamma 2.2).
    let stops = 2.0 * swell(params.progress);
    gpufx_write(id, vec4f(clamp(c.rgb * pow(2.0, stops / 2.2), vec3f(0.0), vec3f(1.0)), c.a));
}
