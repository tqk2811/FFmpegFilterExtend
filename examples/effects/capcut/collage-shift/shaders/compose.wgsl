// Collage Shift, pass 3: the two blurred strips shrink to half height and slide apart, then the second clip opens from the middle.

// The animation runs over 2 s of timeline.
const TIMELINE: f32 = 2.0;

fn timeline_now() -> f32 { return clamp(params.progress, 0.0, 1.0) * TIMELINE; }

// One axis of a cubic bezier through (0, 0), (a, .), (b, .), (1, 1) at curve parameter s.
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

// Same for a point moving along a straight line.
fn key2(cur: vec2f, t: f32, t0: f32, t1: f32, v0: vec2f, v1: vec2f, k: vec4f) -> vec2f {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(k, (t - t0) / (t1 - t0)));
}

// Layout positions are given on a 512 x 724 board.
const BOARD: vec2f = vec2f(512.0, 724.0);

fn spread(t: f32) -> f32 {
    return key(0.0, t, 0.133333, 0.766667, 0.0, 2.0, vec4f(0.166666667, 0.166666667, 0.66666667, 1.0));
}

// Both strips shrink the same way: 100 % -> 65 % -> 50 %.
fn strip_scale(t: f32) -> f32 {
    var s = key(100.0, t, 0.133333, 0.5, 100.0, 65.0, vec4f(0.156878803, 0.443742899, 0.661826879, 0.730784));
    s = key(s, t, 0.5, 0.6, 65.0, 50.0, vec4f(0.43663532, 0.221200446, 0.797444499, 0.984418808));
    return s / 100.0;
}

// Centre of the upper strip: rises to the top quarter, then runs left.
fn top_centre(t: f32) -> vec2f {
    var p = vec2f(256.0, 362.0);
    p = key2(p, t, 0.133333, 0.5, vec2f(256.0, 362.0), vec2f(251.593080912, 182.8697), vec4f(0.166667, 0.166667, 0.666667, 1.0));
    p = key2(p, t, 0.5, 0.866667, vec2f(251.593080912, 182.8697), vec2f(-16.81159416, 182.8697), vec4f(0.166667, 0.166667, 0.833333, 0.82775));
    p = key2(p, t, 0.866667, 1.066667, vec2f(-16.81159416, 182.8697), vec2f(-111.109730192, 182.8697), vec4f(0.166667, 0.267426, 0.833333, 0.863528));
    p = key2(p, t, 1.066667, 1.3, vec2f(-111.109730192, 182.8697), vec2f(-130.109730192, 182.8697), vec4f(0.166667, 0.790207, 0.666667, 1.0));
    return p / BOARD;
}

// Centre of the lower strip: drops to the bottom quarter, then runs right.
fn bottom_centre(t: f32) -> vec2f {
    var p = vec2f(256.0, 362.0);
    p = key2(p, t, 0.133333, 0.5, vec2f(256.0, 362.0), vec2f(284.355213774, 543.0), vec4f(0.166667, 0.166667, 0.666667, 1.0));
    p = key2(p, t, 0.5, 0.866667, vec2f(284.355213774, 543.0), vec2f(418.0, 543.0), vec4f(0.166667, 0.166667, 0.833333, 0.865768));
    p = key2(p, t, 0.866667, 1.066667, vec2f(418.0, 543.0), vec2f(450.701863968, 543.0), vec4f(0.166667, 0.299221, 0.833333, 0.824282));
    p = key2(p, t, 1.066667, 1.3, vec2f(450.701863968, 543.0), vec2f(492.701863968, 543.0), vec4f(0.166667, 0.159619, 0.666667, 1.0));
    return p / BOARD;
}

// Colour (premultiplied) of a strip texture placed with centre `c`, scale `s` and `w` extra widths each side.
fn place(tex: texture_2d<f32>, uv: vec2f, c: vec2f, s: f32, w: f32) -> vec4f {
    let q = (uv - c) / s + 0.5;
    if (q.x < -w || q.x > 1.0 + w || q.y < 0.0 || q.y > 1.0) { return vec4f(0.0); }
    let e = vec2f((q.x + w) / (1.0 + 2.0 * w), q.y);
    let col = textureSampleLevel(tex, smp, e, 0.0);
    return vec4f(col.rgb * col.a, col.a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = timeline_now();
    let w = spread(t);
    let s = strip_scale(t);

    // Lower strip first, the upper strip laid over it, all on black.
    var acc = vec4f(0.0);
    if (t < 1.7) {
        acc = place(strip_bottom, uv, bottom_centre(t), s, w);
        let top = place(strip_top, uv, top_centre(t), s, w);
        acc = top + acc * (1.0 - top.a);
    }

    // The second clip shows in a band that opens from the middle outwards.
    if (t >= 1.3) {
        let k = vec4f(0.166667, 0.16927, 0.833333, 0.763022);
        let upper = key(0.49474938668094, t, 1.3, 1.533333, 0.49474938668094, 1.02527075812293, k);
        let lower = key(0.49723756906077, t, 1.3, 1.533333, 0.49723756906077, -0.00631768953039, vec4f(0.166667, 0.167581, 0.833333, 0.765387));
        // Height measured from the bottom edge; the band edges are about one pixel soft.
        let y = 1.0 - uv.y;
        let px = 1.0 / globals.size.y;
        let inside = clamp((upper - y) / px + 0.5, 0.0, 1.0) * clamp((y - lower) / px + 0.5, 0.0, 1.0);
        let b = textureSampleLevel(second, smp, uv, 0.0);
        acc = vec4f(b.rgb, 1.0) * inside + acc * (1.0 - inside);
    }
    gpufx_write(id, vec4f(acc.rgb, 1.0));
}
