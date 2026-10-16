// Dazzle Pulse, pass 1: cut to the second clip at the peak and smear the picture in a fading zoom blur from the centre.
//
// `progress` 0..1 spans SPAN seconds of scene time; the cut happens at MID.

const SPAN: f32 = 0.7;
const MID: f32 = 0.333333;
const DECAY: f32 = 0.965;
const MAX_STEPS: i32 = 128;

// Cubic-bezier easing (control points (x1, y1), (x2, y2)), solved for x by bisection.
fn ease(u: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let m = 0.5 * (lo + hi);
        let r = 1.0 - m;
        let x = 3.0 * r * r * m * c.x + 3.0 * r * m * m * c.z + m * m * m;
        if (x > u) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * c.y + 3.0 * r * s * s * c.w + s * s * s;
}

// One animated value: v0 before t0, v1 after t1, eased in between.
fn key(t: f32, t0: f32, t1: f32, v0: f32, v1: f32, c: vec4f) -> f32 {
    if (t <= t0) { return v0; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease((t - t0) / (t1 - t0), c));
}

// Rise from 0 to a peak at t1 and fall back to 0 at t2, each half with its own easing.
fn pulse(t: f32, t0: f32, t1: f32, t2: f32, peak: f32, up: vec4f, down: vec4f) -> f32 {
    if (t < t1) { return key(t, t0, t1, 0.0, peak, up); }
    return key(t, t1, t2, peak, 0.0, down);
}

fn grain(p: vec2f) -> f32 {
    var f = fract(p * 13.517);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y);
}

fn pick(q: vec2f, late: bool) -> vec3f {
    if (late) { return textureSampleLevel(second, smp, q, 0.0).rgb; }
    return textureSampleLevel(first, smp, q, 0.0).rgb;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let late = t >= MID;
    let amount = pulse(t, 0.1, MID, 0.566667, 20.0, vec4f(0.166667, 0.166667, 0.48, 1.0), vec4f(0.52, 0.0, 0.833333, 0.833333));
    var color = pick(uv, late);
    if (amount > 0.0) {
        let reach = (uv - vec2f(0.5)) * (amount / 200.0);
        let steps = min(20.0 * 8.0 * (0.9 * length(reach) + 0.1) + 5.0, f32(MAX_STEPS));
        let step = reach / steps;
        let fade = pow(pow(DECAY, 50.0), 1.0 / steps);
        let origin = uv + step * (0.5 * (grain(vec2f(uv.x, 1.0 - uv.y)) * 2.0 - 1.0));
        var sum = color;
        var total = 1.0;
        var w = 1.0;
        for (var i = 1; i <= MAX_STEPS; i++) {
            let k = f32(i);
            if (k > steps) { break; }
            w *= fade;
            let s = origin - step * k;
            // Taps that leave the frame count as black.
            if (all(s >= vec2f(0.0)) && all(s <= vec2f(1.0))) { sum += pick(s, late) * w; }
            total += w;
        }
        color = sum / total;
    }
    gpufx_write(id, vec4f(color, 1.0));
}
