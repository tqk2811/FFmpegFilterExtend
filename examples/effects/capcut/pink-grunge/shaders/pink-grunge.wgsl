// The picture turns into a shaking, motion-blurred negative under a flickering pink and red grunge light leak.

// Animation frames of the grunge layer (25 per second over the one-second transition).
const LEAK_FRAMES: i32 = 25;

// Mean opacity of the grunge layer per animation frame.
const LEAK_ALPHA = array<f32, 25>(
    0.156, 0.201, 0.201, 0.277, 0.274, 0.359, 0.442, 0.495, 0.492, 0.522,
    0.521, 0.523, 0.51, 0.407, 0.436, 0.21, 0.052, 0.042, 0.044, 0.049,
    0.049, 0.231, 0.231, 0.218, 0.218);

// Mean colour of the grunge layer per animation frame.
const LEAK_TINT = array<vec3f, 25>(
    vec3f(0.56, 0.19, 0.11), vec3f(0.62, 0.2, 0.14), vec3f(0.62, 0.2, 0.14), vec3f(0.62, 0.43, 0.34),
    vec3f(0.63, 0.43, 0.34), vec3f(0.75, 0.53, 0.31), vec3f(0.78, 0.44, 0.27), vec3f(0.86, 0.41, 0.28),
    vec3f(0.85, 0.41, 0.28), vec3f(0.75, 0.51, 0.53), vec3f(0.74, 0.5, 0.52), vec3f(0.74, 0.42, 0.47),
    vec3f(0.71, 0.43, 0.47), vec3f(0.76, 0.29, 0.2), vec3f(0.79, 0.26, 0.18), vec3f(0.55, 0.07, 0.07),
    vec3f(0.45, 0.32, 0.31), vec3f(0.34, 0.04, 0.03), vec3f(0.33, 0.04, 0.04), vec3f(0.28, 0.04, 0.02),
    vec3f(0.28, 0.04, 0.03), vec3f(0.69, 0.13, 0.09), vec3f(0.69, 0.13, 0.09), vec3f(0.63, 0.11, 0.08),
    vec3f(0.63, 0.11, 0.08));

// Shake path: per segment start, end, two control points (frame units) and the timing curve.
const PATH_P0 = array<vec2f, 8>(
    vec2f(0.451145, 0.496557), vec2f(0.477347, 0.480797), vec2f(0.533609, 0.462203), vec2f(0.600891, 0.462803),
    vec2f(0.654918, 0.487036), vec2f(0.650047, 0.510836), vec2f(0.580429, 0.518383), vec2f(0.484888, 0.504148));
const PATH_P3 = array<vec2f, 8>(
    vec2f(0.477347, 0.480797), vec2f(0.533609, 0.462203), vec2f(0.600891, 0.462803), vec2f(0.654918, 0.487036),
    vec2f(0.650047, 0.510836), vec2f(0.580429, 0.518383), vec2f(0.484888, 0.504148), vec2f(0.415545, 0.473238));
const PATH_C1 = array<vec2f, 8>(
    vec2f(0.455512, 0.493931), vec2f(0.491091, 0.475071), vec2f(0.5542, 0.459204), vec2f(0.621109, 0.466942),
    vec2f(0.663111, 0.495042), vec2f(0.637632, 0.516061), vec2f(0.552902, 0.517269), vec2f(0.457407, 0.496623));
const PATH_C2 = array<vec2f, 8>(
    vec2f(0.463603, 0.486523), vec2f(0.513019, 0.465202), vec2f(0.580673, 0.458665), vec2f(0.646725, 0.479031),
    vec2f(0.662462, 0.505612), vec2f(0.607955, 0.519498), vec2f(0.512369, 0.511672), vec2f(0.427102, 0.47839));
const PATH_EASE = array<vec4f, 8>(
    vec4f(0.166667, 0.166667, 0.833333, 0.774532), vec4f(0.166667, 0.132191, 0.833333, 0.830081),
    vec4f(0.166667, 0.163536, 0.833333, 0.831049), vec4f(0.166667, 0.164443, 0.833333, 0.861429),
    vec4f(0.166667, 0.209051, 0.833333, 0.787479), vec4f(0.166667, 0.137087, 0.833333, 0.801744),
    vec4f(0.166667, 0.14376, 0.833333, 0.842197), vec4f(0.166667, 0.176585, 0.833333, 0.833333));

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, e: vec4f) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * e.x + 3.0 * inv * s * s * e.z + s * s * s;
        let dx = 3.0 * inv * inv * e.x + 6.0 * inv * s * (e.z - e.x) + 3.0 * s * s * (1.0 - e.z);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * e.y + 3.0 * inv * s * s * e.w + s * s * s;
}

// Frame centre of the shaking picture at time t; segments run every 0.04 s from 0.24 s.
fn shake_centre(t: f32) -> vec2f {
    if (t <= 0.24) { return PATH_P0[0]; }
    if (t >= 0.56) { return PATH_P3[7]; }
    let seg = min(i32((t - 0.24) / 0.04), 7);
    let x = clamp((t - 0.24 - 0.04 * f32(seg)) / 0.04, 0.0, 1.0);
    let s = bezier_ease(x, PATH_EASE[seg]);
    let r = 1.0 - s;
    return r * r * r * PATH_P0[seg] + 3.0 * r * r * s * PATH_C1[seg] + 3.0 * r * s * s * PATH_C2[seg] + s * s * s * PATH_P3[seg];
}

fn mirror(p: vec2f) -> vec2f {
    return abs((p - 1.0) - 2.0 * floor((p - 1.0) / 2.0) - 1.0);
}

fn dither_noise(a: f32, b: f32) -> f32 {
    var q = fract(vec2f(a, b) * 13.517);
    q += dot(q, q.yx + 22.541);
    return fract((q.x + q.y) * q.y);
}

fn clip_at(uv: vec2f, t: f32) -> vec3f {
    if (t < 0.4) { return textureSampleLevel(first, smp, uv, 0.0).rgb; }
    return textureSampleLevel(second, smp, uv, 0.0).rgb;
}

// Picture smeared along the shake path between the lagging and current centre, then inverted.
fn shaken_negative(uv: vec2f, t: f32) -> vec3f {
    let lagging = shake_centre(t - 0.04) - 0.5;
    let current = shake_centre(t) - 0.5;
    let start = lagging + (current - lagging) * 1.65;
    let stop = lagging + (current - lagging) * 2.63;
    let taps = floor(12.0 + 12.0 * smoothstep(0.0, 0.2, length(stop - start)));
    var acc = vec3f(0.0);
    for (var k = 0; k < 24; k++) {
        let fk = f32(k);
        if (fk >= taps) { break; }
        let w = fk / (taps - 1.0) + (dither_noise(fk + uv.x, fk * uv.y) - 0.5) / taps;
        acc += clip_at(mirror(uv - mix(start, stop, w)), t);
    }
    return 1.0 - acc / taps;
}

fn hash21(p: vec2f) -> f32 {
    var q = fract(p * vec2f(123.34, 456.21));
    q += dot(q, q + 45.32);
    return fract(q.x * q.y);
}

fn value_noise(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2f(1.0, 0.0)), u.x),
               mix(hash21(i + vec2f(0.0, 1.0)), hash21(i + vec2f(1.0, 1.0)), u.x), u.y);
}

// Streaky light-leak texture in [0, 1]; mostly vertical bands that change every animation frame.
fn leak_pattern(c: vec2f, frame: f32) -> f32 {
    let seed = vec2f(frame * 7.13, frame * 3.71);
    var n = 0.0;
    var amp = 0.5;
    var scale = vec2f(3.0, 0.8);
    for (var o = 0; o < 4; o++) {
        n += amp * value_noise(c * scale + seed);
        scale *= 2.1;
        amp *= 0.5;
    }
    return clamp((n - 0.47) * 2.2 + 0.5, 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    // Exact clips at the ends, so the transition joins the cut seamlessly.
    if (t <= 0.0) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    if (t >= 1.0) {
        gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    // Hard cut to the second clip at 0.4 s; the negative shake runs from 0.16 s to 0.68 s.
    var color = clip_at(uv, t);
    if (t >= 0.16 && t < 0.68) {
        color = shaken_negative(uv, t);
    }

    let frame = min(i32(t * f32(LEAK_FRAMES)), LEAK_FRAMES - 1);
    let side = max(globals.size.x, globals.size.y);
    let c = (uv - 0.5) * globals.size / side + 0.5;
    let n = leak_pattern(c, f32(frame));
    let m = leak_pattern(c + 3.7, f32(frame) + 0.5);
    let alpha = clamp(LEAK_ALPHA[frame] * (0.25 + 1.5 * n), 0.0, 1.0);
    let tint = clamp(LEAK_TINT[frame] * (0.55 + 0.9 * m), vec3f(0.0), vec3f(1.0));
    gpufx_write(id, vec4f(mix(color, tint, alpha), 1.0));
}
