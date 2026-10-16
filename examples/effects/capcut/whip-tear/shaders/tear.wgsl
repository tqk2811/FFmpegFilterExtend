// Whip Tear, pass 1: the first clip splits down the middle, each half bows and whips off sideways with motion blur.
//
// Output: the torn halves, premultiplied alpha (transparent where they have left).
// The motion follows keyframed curves on a 0.8333 s timeline (progress 0..1 maps onto it).

const SPAN: f32 = 0.8333333;
const FRAME_LAG: f32 = 0.0333333; // the motion blur trails one 30 fps frame behind
const ARC_STEPS: i32 = 64;

// Horizontal centre of each half over time: three eased segments, each a 1-D spatial Bezier.
const SEG_T: array<f32, 4> = array<f32, 4>(0.0, 0.266667, 0.666667, 0.833333);
const RIGHT_EASE: array<vec4f, 3> = array<vec4f, 3>(
    vec4f(0.166667, 0.50819, 0.657505, 0.447072),
    vec4f(0.31501, 0.475327, 0.66, 1.0),
    vec4f(0.34, 0.0, 0.780127, 1.0));
const RIGHT_PATH: array<vec4f, 3> = array<vec4f, 3>(
    vec4f(0.5, 0.52011494, 0.59195402, 0.62068966),
    vec4f(0.62068966, 0.64942529, 0.59597701, 0.67241379),
    vec4f(0.67241379, 0.74885057, 1.01149426, 1.07931034));
const LEFT_EASE: array<vec4f, 3> = array<vec4f, 3>(
    vec4f(0.166667, 0.50819, 0.657505, 0.447072),
    vec4f(0.31501, 0.481916, 0.66, 1.0),
    vec4f(0.34, 0.0, 0.780127, 1.0));
const LEFT_PATH: array<vec4f, 3> = array<vec4f, 3>(
    vec4f(0.5, 0.47988506, 0.40804598, 0.37931034),
    vec4f(0.37931034, 0.35057471, 0.40229885, 0.32758621),
    vec4f(0.32758621, 0.25287357, -0.00287357, -0.06896552));

fn bez(a: f32, b: f32, c: f32, d: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return a * r * r * r + 3.0 * b * r * r * s + 3.0 * c * r * s * s + d * s * s * s;
}

// Timing curve through (0,0), (e.x,e.y), (e.z,e.w), (1,1): find the curve point at x = u, return its y.
fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 18; i++) {
        let mid = 0.5 * (lo + hi);
        if (bez(0.0, e.x, e.z, 1.0, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bez(0.0, e.y, e.w, 1.0, 0.5 * (lo + hi));
}

// Point a fraction f of the way along the path a..d, measured by distance travelled.
fn along_path(p: vec4f, f: f32) -> f32 {
    var total = 0.0;
    var last = p.x;
    for (var i = 1; i <= ARC_STEPS; i++) {
        let x = bez(p.x, p.y, p.z, p.w, f32(i) / f32(ARC_STEPS));
        total += abs(x - last);
        last = x;
    }
    let goal = clamp(f, 0.0, 1.0) * total;
    var acc = 0.0;
    last = p.x;
    for (var i = 1; i <= ARC_STEPS; i++) {
        let x = bez(p.x, p.y, p.z, p.w, f32(i) / f32(ARC_STEPS));
        let step_len = abs(x - last);
        if (acc + step_len >= goal) {
            let s = (f32(i - 1) + (goal - acc) / max(step_len, 1e-9)) / f32(ARC_STEPS);
            return bez(p.x, p.y, p.z, p.w, s);
        }
        acc += step_len;
        last = x;
    }
    return p.w;
}

fn half_centre(right: bool, t: f32) -> f32 {
    if (t < SEG_T[0]) { return 0.5; }
    for (var k = 0; k < 3; k++) {
        if (t < SEG_T[k + 1]) {
            let u = (t - SEG_T[k]) / (SEG_T[k + 1] - SEG_T[k]);
            if (right) { return along_path(RIGHT_PATH[k], ease(RIGHT_EASE[k], u)); }
            return along_path(LEFT_PATH[k], ease(LEFT_EASE[k], u));
        }
    }
    if (right) { return RIGHT_PATH[2].w; }
    return LEFT_PATH[2].w;
}

// How much the halves bow (-1..1): 0 -> 0.25 -> -0.3 -> 0.89.
fn bow(t: f32) -> f32 {
    if (t < 0.066667) { return 0.0; }
    if (t < 0.266667) { return mix(0.0, 0.25, ease(vec4f(0.166667, 0.166667, 0.46, 1.0), (t - 0.066667) / 0.2)); }
    if (t < 0.666667) { return mix(0.25, -0.3, ease(vec4f(0.54, 0.0, 0.66, 1.0), (t - 0.266667) / 0.4)); }
    if (t < 0.833333) { return mix(-0.3, 0.89, ease(vec4f(0.34, 0.0, 0.833333, 1.0), (t - 0.666667) / 0.166666)); }
    return 0.89;
}

// Overall zoom: 1 -> 1.1 -> 1.
fn zoom(t: f32) -> f32 {
    if (t < 0.266667) { return mix(1.0, 1.1, ease(vec4f(0.166667, 0.166667, 0.25, 1.0), t / 0.266667)); }
    if (t < 0.833333) { return mix(1.1, 1.0, ease(vec4f(0.75, 0.0, 0.833333, 0.833333), (t - 0.266667) / 0.566666)); }
    return 1.0;
}

fn inside(q: vec2f) -> bool {
    return all(q >= vec2f(0.0)) && all(q <= vec2f(1.0));
}

// Bend the picture along a vertical arc. `a` is the coordinate across the bend, `b` along it;
// `mirror` bends the other side (the two halves bow in opposite directions).
fn arc_bend(a_in: f32, b_in: f32, amount: f32, mirror: bool) -> vec2f {
    let aspect = globals.size.x / globals.size.y;
    var p = vec2f(a_in, b_in);
    if (mirror) { p = vec2f(1.0) - p; }
    let off = p.x - 0.5;
    let r = 1.0 / pow(clamp(abs(amount), 1e-5, 1.0), 0.57) - 1.0;
    let big = sqrt(r * r + 0.25);
    let sag = sqrt(big * big - off * off) - r;
    var lift = sag * aspect + 1.0;
    if (amount < 0.0) { lift = 1.0 - sag * aspect; }
    p.y = p.y / lift;
    p.x = p.x - 0.5;
    let k = abs(abs(p.x) * 2.0 - 0.5);
    p.x = p.x * mix(1.0, k * k * k * 2.0 + 0.75, p.y * clamp(abs(amount), 0.0, 1.0));
    p.x = p.x + 0.5;
    if (mirror) { p = vec2f(1.0) - p; }
    return vec2f(p.y, p.x);
}

// One half of the cut first clip, bowed, before it moves.
fn bowed_half(q: vec2f, right: bool, amount: f32) -> vec4f {
    let w = arc_bend(q.y, q.x, amount, !right);
    if (!inside(w)) { return vec4f(0.0); }
    let keep = select((w.x < 0.5), (w.x > 0.5), right);
    if (!keep) { return vec4f(0.0); }
    return vec4f(textureSampleLevel(first, smp, w, 0.0).rgb, 1.0);
}

fn jitter(a: f32, b: f32) -> f32 {
    let f = fract(vec2f(a, b) * 13.517);
    let g = f + dot(f, f.yx + vec2f(22.541));
    return fract((g.x + g.y) * g.y);
}

// The half sliding to its place at time t, smeared along its last frame of motion.
fn moving_half(q: vec2f, right: bool, t: f32, amount: f32) -> vec4f {
    let now = half_centre(right, t) - 0.5;
    let before = half_centre(right, t - FRAME_LAG) - 0.5;
    let from_x = mix(before, now, 0.75);
    let to_x = mix(before, now, 1.25);
    let a = q - vec2f(from_x, 0.0);
    let b = q - vec2f(to_x, 0.0);
    let n = floor(12.0 + 12.0 * smoothstep(0.0, 0.2, distance(a, b)));
    var acc = vec4f(0.0);
    for (var k = 0.0; k < 24.0; k += 1.0) {
        if (k >= n) { break; }
        let f = k / (n - 1.0) + (jitter(k + q.x, k * q.y) - 0.5) / n;
        let s = mix(a, b, f);
        if (inside(s)) { acc += bowed_half(s, right, amount); }
    }
    return acc / n;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let q = (uv - vec2f(0.5)) / zoom(t) + vec2f(0.5);
    if (!inside(q)) { gpufx_write(id, vec4f(0.0)); return; }
    let amount = bow(t);
    let left = moving_half(q, false, t, amount);
    let right = moving_half(q, true, t, amount);
    gpufx_write(id, right + left * (1.0 - right.a));
}
