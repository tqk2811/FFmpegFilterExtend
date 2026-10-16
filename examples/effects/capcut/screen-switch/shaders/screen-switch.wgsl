// Screen Switch, pass 3 (keyframes shared with the card passes): the first clip shrinks into a rounded, lens-curved card that flies up out of frame with motion blur while the second card flies in from below and settles to full screen.

// The animation runs over 2 s of timeline.
const TIMELINE: f32 = 2.0;
// The motion blur spans from three quarters to five quarters of one 30 fps frame.
const FRAME_STEP: f32 = 1.0 / 30.0;
const BLUR_TAPS: i32 = 24;
const LAYER_ZOOM: vec2f = vec2f(512.0 / 509.0, 724.0 / 720.0);

fn timeline_now() -> f32 { return clamp(params.progress, 0.0, 1.0) * TIMELINE; }

fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

// Keyframe easing: find s where the x axis reaches u, return the y axis there.
fn ease(k: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(k.x, k.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(k.y, k.w, 0.5 * (lo + hi));
}

// One keyframe segment: keeps `cur` before t0, eases from v0 to v1 inside, holds v1 after.
fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, k: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return v0 + (v1 - v0) * ease(k, (t - t0) / (t1 - t0));
}

const LINEAR = vec4f(0.166666667, 0.166666667, 0.833333333, 0.833333333);
const SMOOTH = vec4f(0.333333, 0.0, 0.666667, 1.0);

// Card state: x = corner radius (of 256), y = lens strength (degrees), z = height of the centre
// measured from the bottom (0..1), w = scale.
fn outgoing_state(t: f32) -> vec4f {
    let radius = key(0.0, t, 0.533333, 0.633333, 0.0, 50.0, LINEAR);
    let lens = key(0.0, t, 0.633333, 1.0, 0.0, 20.0, LINEAR);
    let y = key(0.5, t, 1.133333, 1.4, 0.5, 1.6859205776174, LINEAR);
    let s = key(1.0, t, 0.4, 1.133333, 1.0, 0.8, LINEAR);
    return vec4f(radius, lens, y, s);
}

fn incoming_state(t: f32) -> vec4f {
    let radius = key(50.0, t, 1.7, 1.9, 50.0, 0.0, LINEAR);
    let lens = key(20.0, t, 1.533333, 1.866667, 20.0, 0.0, LINEAR);
    let y = key(-0.43772563176934, t, 1.133333, 1.4, -0.43772563176934, 0.5, SMOOTH);
    var s = key(1.0, t, 0.4, 1.133333, 1.0, 0.8, LINEAR);
    s = key(s, t, 1.666667, 1.933333, 0.8, 1.0, LINEAR);
    return vec4f(radius, lens, y, s);
}

// Small hash in 0..1 for the blur jitter.
fn jitter(a: f32, b: f32) -> f32 {
    var p = fract(vec2f(a, b) * 13.517);
    p += dot(p, p.yx + 22.541);
    return fract((p.x + p.y) * p.y);
}

// Where along the blur path, piecewise linear through the six key positions.
fn along(s: f32, pts: array<vec2f, 6>) -> vec2f {
    let seg = clamp(i32(floor(s * 5.0)), 0, 4);
    return mix(pts[seg], pts[seg + 1], s * 5.0 - f32(seg));
}

// One moving card (already shaped by step 1) with motion blur between its previous-frame and current placement.
fn moving_card(tex: texture_2d<f32>, g: vec2f, now: vec4f, before: vec4f) -> vec4f {
    var pts: array<vec2f, 6>;
    for (var i = 0; i < 6; i++) {
        let w = 0.75 + 0.1 * f32(i);
        let y = mix(before.z, now.z, w);
        let s = mix(before.w, now.w, w);
        pts[i] = (g - vec2f(0.5, y)) / s + 0.5;
    }
    var acc = vec4f(0.0);
    for (var n = 0; n < BLUR_TAPS; n++) {
        let fn_ = f32(n);
        let s = fn_ / f32(BLUR_TAPS - 1) + (jitter(fn_ + g.x, fn_ * g.y) - 0.5) / f32(BLUR_TAPS);
        let q = along(s, pts);
        if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
            acc += textureSampleLevel(tex, smp, vec2f(q.x, 1.0 - q.y), 0.0);
        }
    }
    return acc / f32(BLUR_TAPS);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = timeline_now();
    // Both cards sit on a layer drawn slightly larger than the frame (a 512 x 724 layer on a 509 x 720 board).
    let g = (vec2f(uv.x, 1.0 - uv.y) - 0.5) / LAYER_ZOOM + 0.5;
    var acc = vec4f(0.0);
    if (t < 1.6) {
        acc = moving_card(card_first, g, outgoing_state(t), outgoing_state(t - FRAME_STEP));
    }
    if (t >= 1.133333) {
        let top = moving_card(card_second, g, incoming_state(t), incoming_state(t - FRAME_STEP));
        acc = top + acc * (1.0 - top.a);
    }
    gpufx_write(id, vec4f(acc.rgb, 1.0));
}
