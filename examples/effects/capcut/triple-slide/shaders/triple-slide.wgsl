// The frame splits into three columns: the outer two push the first clip down and the middle one pushes it up, with motion blur, while the whole picture bobs in a zoom.

// Animation time covered by progress 0..1, in seconds.
const SPAN: f32 = 1.33333;
// Time between the current and the trailing pose used for the motion blur.
const LAG: f32 = 0.033333;
// Column edges (fractions of the width); the middle column overlaps its neighbours by a hair.
const LEFT_EDGE: f32 = 0.3;
const MID_LO: f32 = 0.299;
const MID_HI: f32 = 0.701;
const RIGHT_EDGE: f32 = 0.7;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
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

// Eased 0..1 ramp between times t0 and t1.
fn ramp(t: f32, t0: f32, t1: f32, c: vec4f) -> f32 {
    return bezier_ease(clamp((t - t0) / (t1 - t0), 0.0, 1.0), c);
}

// Soft start, hard landing (used for the small lead-in drift).
const EASE_LEAD: vec4f = vec4f(0.166667, 0.166667, 0.14, 1.0);
// Strong ease in and out (used for the main slide).
const EASE_SLIDE: vec4f = vec4f(0.86, 0.0, 0.14, 1.0);

// Vertical content offset of a column at time t (positive = content moved up).
// kind 0: first clip, outer column; 1: first clip, middle; 2: second clip, outer; 3: second clip, middle.
fn column_shift(kind: i32, t: f32) -> f32 {
    let lead = ramp(t, 0.0, 0.666667, EASE_LEAD);
    let slide = ramp(t, 0.666667, 1.3, EASE_SLIDE);
    switch kind {
        case 0: { return 0.068966 * lead - 1.131034 * slide; }
        case 1: { return -0.068966 * lead + 1.091379 * slide; }
        case 2: { return 0.925862 - 0.925862 * slide; }
        default: { return -0.936207 + 0.936207 * slide; }
    }
}

// Stable per-sample jitter so the blur steps do not band.
fn jitter(a: f32, b: f32) -> f32 {
    let f = fract(vec2f(a, b) * 13.517);
    let g = f + dot(f, f.yx + 22.541);
    return fract((g.x + g.y) * g.y);
}

// One column of a clip, moved vertically and motion-blurred along its path.
// Returns premultiplied colour + coverage.
fn column_layer(which: i32, kind: i32, p: vec2f, t: f32) -> vec4f {
    let now = column_shift(kind, t);
    let before = column_shift(kind, t - LAG);
    // The blur spans the pose extrapolated from 0.75 to 2.55 steps of the recent motion.
    let a = before + (now - before) * 0.75;
    let b = before + (now - before) * 2.55;
    let taps = floor(12.0 + 12.0 * smoothstep(0.0, 0.2, abs(b - a)));
    var acc = vec4f(0.0);
    for (var i = 0; i < 24; i++) {
        let fi = f32(i);
        if (fi >= taps) { break; }
        let f = fi / (taps - 1.0) + (jitter(fi + p.x, fi * p.y) - 0.5) / taps;
        let q = vec2f(p.x, p.y + mix(a, b, f));
        if (q.y < 0.0 || q.y > 1.0) { continue; }
        var c: vec3f;
        if (which == 0) {
            c = textureSampleLevel(first, smp, q, 0.0).rgb;
        } else {
            c = textureSampleLevel(second, smp, q, 0.0).rgb;
        }
        acc += vec4f(c, 1.0);
    }
    return acc / taps;
}

fn over(dst: vec4f, src: vec4f) -> vec4f {
    return src + dst * (1.0 - src.a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;

    // Whole-picture bob: zoom up to 121 % and a small drift right/down, then back.
    var zoom: f32;
    if (t < 0.566667) {
        zoom = 1.0 + 0.21 * ramp(t, 0.0, 0.566667, vec4f(0.166667, 0.166667, 0.36, 1.0));
    } else {
        zoom = 1.21 - 0.21 * ramp(t, 0.566667, 1.3, vec4f(0.64, 0.0, 0.36, 1.0));
    }
    var drift: f32;
    if (t < 0.666667) {
        drift = ramp(t, 0.0, 0.666667, EASE_LEAD);
    } else {
        drift = 1.0 - ramp(t, 0.666667, 1.3, EASE_SLIDE);
    }
    let p = 0.5 + (uv - 0.5 - vec2f(0.041379, 0.003448) * drift) / zoom;
    if (any(p < vec2f(0.0)) || any(p > vec2f(1.0))) { gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0)); return; }

    // Stack bottom to top: second clip columns, then first clip columns.
    var acc = vec4f(0.0);
    if (p.x <= LEFT_EDGE) { acc = over(acc, column_layer(1, 2, p, t)); }
    if (p.x >= MID_LO && p.x <= MID_HI) { acc = over(acc, column_layer(1, 3, p, t)); }
    if (p.x >= RIGHT_EDGE) { acc = over(acc, column_layer(1, 2, p, t)); }
    if (p.x <= LEFT_EDGE) { acc = over(acc, column_layer(0, 0, p, t)); }
    if (p.x >= MID_LO && p.x <= MID_HI) { acc = over(acc, column_layer(0, 1, p, t)); }
    if (p.x >= RIGHT_EDGE) { acc = over(acc, column_layer(0, 0, p, t)); }
    gpufx_write(id, vec4f(acc.rgb, 1.0));
}
