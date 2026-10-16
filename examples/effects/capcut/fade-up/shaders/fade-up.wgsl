// Fade up: the first clip drifts up, doubles in size and fades over the second, zoom-blurred and waved, with an early flash.

// The animation is laid out on a 1.5 s timeline.
const TIMELINE: f32 = 1.5;
const TAU: f32 = 6.2831853;
// Lengths below are in pixels of a 720-line reference frame.
const REF_LINES: f32 = 720.0;
// Point the zoom blur streams away from (bottom centre).
const BLUR_CENTRE = vec2f(0.5, BLUR_Y);
const BLUR_Y: f32 = 1.0;

// CSS-like cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1), solved for x by bisection.
fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(x1: f32, y1: f32, x2: f32, y2: f32, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(x1, x2, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(y1, y2, 0.5 * (lo + hi));
}

// One keyframe segment: keeps `cur` before `t0`, eases from v0 to v1 inside, holds v1 after.
fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, e: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(e.x, e.y, e.z, e.w, (t - t0) / (t1 - t0)));
}

const SNAP = vec4f(0.333333, 0.0, 0.0, 1.0);
const SMOOTH = vec4f(0.33333333, 0.0, 0.66666667, 1.0);

fn jitter(p: vec2f) -> f32 {
    let f = fract(p * 13.517);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

fn inside(q: vec2f) -> bool {
    return all(q >= vec2f(0.0)) && all(q <= vec2f(1.0));
}

// Zoom blur of the first clip around BLUR_CENTRE; taps past the frame count as transparent black.
fn zoom_blur(q: vec2f, amount: f32) -> vec4f {
    var acc = textureSampleLevel(first, smp, q, 0.0);
    let reach = (q - BLUR_CENTRE) * amount;
    let taps = min(160.0 * (0.9 * length(reach) + 0.1) + 5.0, 128.0);
    let stride = reach / taps;
    let start = q + stride * 0.5 * (jitter(q) * 2.0 - 1.0);
    var total = 1.0;
    for (var k = 1.0; k <= 128.0; k += 1.0) {
        if (k > taps) { break; }
        let s = start - stride * k;
        total += 1.0;
        if (inside(s)) { acc += textureSampleLevel(first, smp, s, 0.0); }
    }
    return acc / total;
}

// Vertical sine ripple travelling along x; the frame edges stay pinned.
fn wave(q: vec2f, amp_px: f32, phase: f32) -> vec2f {
    let size = globals.size;
    let unit = size.y / REF_LINES;
    let amp = amp_px * unit;
    let p = q * size;
    let shift = sin(TAU * fract(p.x / (450.0 * unit) + phase)) * amp;
    let moved = p - vec2f(0.0, shift);
    let margin = vec2f(amp * 1.2);
    let near = min(clamp(p / margin, vec2f(0.0), vec2f(1.0)), clamp((size - p) / margin, vec2f(0.0), vec2f(1.0)));
    var hold = min(near.x, near.y);
    if (amp <= 0.0) { hold = 0.0; }
    return mix(p, moved, hold) / size;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;
    let u = t / TIMELINE;

    // Layer motion: the centre climbs to the top edge while the size doubles.
    let lift = key(0.0, t, 0.0, TIMELINE, 0.0, 1.0, SNAP);
    let grow = key(1.0, t, 0.0, TIMELINE, 1.0, 2.0, SNAP);
    let centre = vec2f(0.5, 0.5 * (1.0 - lift));
    let q = vec2f(0.5) + (uv - centre) / grow;

    let fade = 1.0 - u;
    let blur = 90.0 * u / 200.0;
    let ripple = 20.0 * u;
    let phase = -(params.progress * params.duration * 2.0);

    let w = wave(q, ripple, phase);
    var layer = vec4f(0.0);
    if (inside(q) && inside(w)) { layer = zoom_blur(w, blur); }
    layer *= fade;
    let back = textureSampleLevel(second, smp, uv, 0.0);
    var c = layer.rgb + back.rgb * (1.0 - layer.a);

    // Brief exposure flash in linear light (+3 stops at its peak).
    var stops = key(0.0, t, 0.033333, 0.2, 0.0, 3.0, SMOOTH);
    stops = key(stops, t, 0.2, 0.366667, 3.0, 0.0, SMOOTH);
    if (stops > 0.0) {
        c = clamp(pow(pow(max(c, vec3f(0.0)), vec3f(2.2)) * exp2(stops), vec3f(1.0 / 2.2)), vec3f(0.0), vec3f(1.0));
    }
    gpufx_write(id, vec4f(c, 1.0));
}
