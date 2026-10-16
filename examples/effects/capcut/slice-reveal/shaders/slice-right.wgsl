// Slice reveal, step 2: the right diagonal half of the first clip, slid sideways with motion blur.

// The animation is laid out on a 2 s timeline; the blur trails one 1/30 s frame of motion.
const TIMELINE: f32 = 2.0;
const FRAME: f32 = 0.0333333;
// Horizontal centre of this half at the hold point and at the end.
const MID_X: f32 = 0.8828125;
const END_X: f32 = 1.5078125;
// Which side of the diagonal this half keeps (+1 = above x = y in a y-up frame).
const SIDE: f32 = -1.0;
const CUT_Y_UP: bool = true;

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

// Horizontal shift of the half: a fast push out to MID_X, then a slow-in drift to END_X.
fn shift_at(t: f32) -> f32 {
    if (t <= 0.0) { return 0.0; }
    if (t < 0.666667) {
        return (MID_X - 0.5) * ease(0.333333, 0.0, 0.0, 1.0, t / 0.666667);
    }
    let u = clamp((t - 0.666667) / (TIMELINE - 0.666667), 0.0, 1.0);
    return mix(MID_X - 0.5, END_X - 0.5, ease(0.756667, 0.0, 0.5, 1.0, u));
}

fn jitter(a: f32, b: f32) -> f32 {
    let f = fract(vec2f(a, b) * 13.517);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

// The masked half of the first clip at q; transparent outside the frame or past the cut.
fn half_at(q: vec2f) -> vec4f {
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return vec4f(0.0); }
    var y = q.y;
    if (CUT_Y_UP) { y = 1.0 - q.y; }
    if (SIDE * (y - q.x) <= 0.0) { return vec4f(0.0); }
    return vec4f(textureSampleLevel(first, smp, q, 0.0).rgb, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;
    let now = shift_at(t);
    let before = shift_at(t - FRAME);
    // The streak spans 0.75..1.25 of the way from last frame's place to this frame's.
    let a = mix(before, now, 0.75);
    let b = mix(before, now, 1.25);
    let n = floor(12.0 + 12.0 * smoothstep(0.0, 0.2, abs(b - a)));
    var acc = vec4f(0.0);
    for (var k = 0.0; k < 24.0; k += 1.0) {
        if (k >= n) { break; }
        let s = k / (n - 1.0) + (jitter(k + uv.x, k * uv.y) - 0.5) / n;
        acc += half_at(uv - vec2f(mix(a, b, s), 0.0));
    }
    // Stored premultiplied: rgb already carries the coverage in alpha.
    acc /= n;
    gpufx_write(id, acc);
}
