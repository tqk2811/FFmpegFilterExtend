// Slide film, step 1: the clip shrinks into a rounded frame and squashes into a strip of repeated frames; the second strip drops in and springs back to full size.

// The animation is laid out over 0.7 s of timeline; the second clip takes over at 0.233333 s.
const TIMELINE: f32 = 0.7;
const SWITCH_AT: f32 = 0.233333;

fn timeline_now() -> f32 { return clamp(params.progress, 0.0, 1.0) * TIMELINE; }

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

const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

fn mirror01(q: vec2f) -> vec2f {
    return abs(((q - 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
}

// Frame of the clip shrunk to `zoom` about the centre with corners rounded by `radius`
// (pixels of a 1080-pixel frame); black around it.
fn framed(tex: texture_2d<f32>, q: vec2f, zoom: f32, radius: f32) -> vec3f {
    let inner = (q - 0.5) / zoom + 0.5;
    if (any(inner < vec2f(0.0)) || any(inner > vec2f(1.0))) { return vec3f(0.0); }
    let px = inner * globals.size;
    let r = radius * min(globals.size.x, globals.size.y) / 1080.0;
    let edge = min(px, globals.size - px);
    var cover = 1.0;
    if (r > 0.0 && edge.x < r && edge.y < r) {
        let d = length(vec2f(r) - edge) - r;
        cover = clamp(0.5 - d, 0.0, 1.0);
    }
    return textureSampleLevel(tex, smp, inner, 0.0).rgb * cover;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = timeline_now();
    let uv = gpufx_uv(id);
    var c: vec3f;
    if (t < SWITCH_AT) {
        let radius = key(0.0, t, 0.0, 0.233333, 0.0, 55.0, vec4f(0.21, 0.0, 0.3, 1.0));
        let zoom = key(100.0, t, 0.0, 0.233333, 100.0, 66.0, vec4f(0.58, 0.1, 0.75, 1.0)) / 100.0;
        // Strip: stretched to 120 % wide, squashed to 30 % tall about the bottom edge, repeated mirrored.
        let sx = key(100.0, t, 0.0, 0.233333, 100.0, 120.0, vec4f(0.62, 0.0, 0.999, 1.0)) / 100.0;
        let sy = key(100.0, t, 0.0, 0.233333, 100.0, 30.0, vec4f(0.62, 0.0, 0.999, 1.0)) / 100.0;
        let q = vec2f((uv.x - 0.5) / sx + 0.5, (uv.y - 1.0) / sy + 1.0);
        c = framed(first, mirror01(q), zoom, radius);
    } else {
        let radius = key(55.0, t, 0.233333, 0.7, 55.0, 0.0, vec4f(0.62, 0.0, 0.77, 1.0));
        let zoom = key(66.0, t, 0.233333, 0.7, 66.0, 100.0, vec4f(0.25, 0.0, 0.44, 0.92)) / 100.0;
        // The strip drops from above the frame, overshoots and settles (pixels of a 1080 frame).
        var y = key(-540.0, t, 0.233333, 0.4, -540.0, 639.0, vec4f(0.001, 0.0, 0.5, 1.0));
        y = key(y, t, 0.4, 0.566667, 639.0, 515.0, vec4f(0.22, 0.0, 0.48, 1.0));
        y = key(y, t, 0.566667, 0.7, 515.0, 540.0, vec4f(0.27, 0.0, 0.55, 1.0));
        var sx = key(121.0, t, 0.233333, 0.466667, 121.0, 99.0, vec4f(0.001, 0.0, 0.23, 0.923636364));
        sx = key(sx, t, 0.466667, 0.633333, 99.0, 100.0, vec4f(0.27, 0.06, 0.58, 1.0));
        var sy = key(30.0, t, 0.233333, 0.466667, 30.0, 103.0, vec4f(0.001, 0.0, 0.23, 0.92));
        sy = key(sy, t, 0.466667, 0.633333, 103.0, 100.0, vec4f(0.27, 0.06, 0.58, 1.0));
        let centre = vec2f(0.5, y / 1080.0);
        let q = (uv - centre) / (vec2f(sx, sy) / 100.0) + 0.5;
        c = framed(second, mirror01(q), zoom, radius);
    }
    gpufx_write(id, vec4f(c, 1.0));
}
