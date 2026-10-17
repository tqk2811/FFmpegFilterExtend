// Whirl, step 1: the second clip as a round-cornered card tumbling in 3D, smeared along its motion.

const SPAN: f32 = 0.933333;
const FRAME: f32 = 0.0333333;
const FOV_X: f32 = 39.6;
const TAPS: f32 = 14.0;
const DITHER: f32 = 0.8;
const NO_HIT = vec2f(-10000.0);

fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

// Cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1), x solved by bisection.
fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(e.x, e.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(e.y, e.w, 0.5 * (lo + hi));
}

// One keyframe segment: keeps `cur` before t0, eases v0 -> v1 inside, holds v1 after.
fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, e: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(e, (t - t0) / (t1 - t0)));
}

fn lift(t: f32) -> f32 {
    var v = key(-0.36328125, t, 0.0, 0.133333, -0.36328125, 0.0734914, vec4f(0.631994, 0.0, 0.877124, 0.733984));
    v = key(v, t, 0.133333, 0.2, 0.0734914, 0.3648918, vec4f(0.337527, 0.547625, 0.213829, 0.492142));
    return key(v, t, 0.2, 0.533333, 0.3648918, 0.5, vec4f(0.143548, 1.0, 0.927527, 1.0));
}

fn size_at(t: f32) -> f32 {
    let v = key(0.5, t, 0.0, 0.533333, 0.5, 0.65, vec4f(0.675322343, 0.002828525, 0.818133917, 0.132019647));
    return key(v, t, 0.533333, 0.9, 0.65, 1.0, vec4f(0.154302471, 0.314194981, 0.281619755, 0.9931526));
}

fn tilt_at(t: f32) -> vec3f {
    var x = key(360.0, t, 0.0, 0.169987, 360.0, 304.2, vec4f(0.333333333, -0.552311378, 0.666666667, 1.0));
    x = key(x, t, 0.169987, 0.266667, 304.2, 135.891226, vec4f(0.412609673, 0.001696874, 0.740087462, 0.883526094));
    x = key(x, t, 0.266667, 0.333333, 135.891226, 65.0, vec4f(0.999934503, 0.733602384, 0.9999, 0.999991798));
    x = key(x, t, 0.333333, 0.533333, 65.0, 0.0, vec4f(0.0001, 0.0, 0.573333502, 0.961000142));
    var y = key(-1.1, t, 0.0, 0.166667, -1.1, 26.9, vec4f(0.166666667, 0.0, 0.666666668, 1.0));
    y = key(y, t, 0.166667, 0.266667, 26.9, -48.654709, vec4f(0.412609673, 0.003909846, 0.740087462, 0.960053852));
    y = key(y, t, 0.266667, 0.333333, -48.654709, -15.0, vec4f(0.999934503, -0.230008385, 0.999841261, 1.000011777));
    y = key(y, t, 0.333333, 0.533333, -15.0, 0.0, vec4f(0.0001, 0.0, 0.0, 0.732514383));
    var z = key(95.387302, t, 0.0, 0.119987, 95.387302, 76.590095, vec4f(0.333333334, 0.529403193, 0.666666669, 0.663058423));
    z = key(z, t, 0.119987, 0.166667, 76.590095, 55.8, vec4f(0.333333334, 0.118518257, 0.666666668, 1.0));
    z = key(z, t, 0.166667, 0.333333, 55.8, -10.0, vec4f(1.0, 0.018134458, 0.9999, 0.999990513));
    z = key(z, t, 0.333333, 0.533333, -10.0, 0.0, vec4f(0.49343334, 0.518401693, 0.533333421, 0.968100383));
    return vec3f(x, y, z);
}

fn smear_at(t: f32) -> f32 {
    var v = key(0.19, t, 0.0, 0.166667, 0.19, 0.1, vec4f(0.199370788, -0.640834676, 0.569093197, 2.778385827));
    v = key(v, t, 0.166667, 0.333333, 0.1, 0.05, vec4f(0.320953106, -2.384277089, 0.703004582, 1.0));
    v = key(v, t, 0.333333, 0.433333, 0.05, 0.68, vec4f(0.333333331, 0.0, 0.666666665, 1.01118623));
    v = key(v, t, 0.433333, 0.533333, 0.68, 0.3, vec4f(0.333333332, 0.018545591, 0.666666666, 1.732077104));
    v = key(v, t, 0.533333, 0.7, 0.3, 0.31, vec4f(0.333333335, 46.364883385, 0.66666667, 1.0));
    v = key(v, t, 0.7, 0.8, 0.31, 1.37, vec4f(0.456624068, -0.003073585, 0.774008064, 1.133570073));
    return key(v, t, 0.8, 0.9, 1.37, 0.0, vec4f(0.760479581, 0.347767566, 0.4860608, 1.0));
}

fn corner_at(t: f32) -> f32 {
    return key(46.0, t, 0.6, 0.933333, 46.0, 0.0, vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333)) / 1280.0;
}

struct Pose { lift: f32, size: f32, tilt: vec3f, drop: f32 };

fn pose_at(t: f32) -> Pose {
    return Pose(lift(t), size_at(t), tilt_at(t), 1.0 - smoothstep(0.0, 0.133333, t));
}

fn turn_x(a: f32) -> mat3x3f {
    let c = cos(a); let s = sin(a);
    return mat3x3f(vec3f(1.0, 0.0, 0.0), vec3f(0.0, c, s), vec3f(0.0, -s, c));
}
fn turn_y(a: f32) -> mat3x3f {
    let c = cos(a); let s = sin(a);
    return mat3x3f(vec3f(c, 0.0, -s), vec3f(0.0, 1.0, 0.0), vec3f(s, 0.0, c));
}
fn turn_z(a: f32) -> mat3x3f {
    let c = cos(a); let s = sin(a);
    return mat3x3f(vec3f(c, s, 0.0), vec3f(-s, c, 0.0), vec3f(0.0, 0.0, 1.0));
}

// Where the camera ray of screen point `ndc` (y up) meets the card, in card uv (y up); NO_HIT when it
// misses (both faces are drawn).
fn card_hit(ndc: vec2f, p: Pose, aspect: f32) -> vec2f {
    let depth = aspect / tan(radians(FOV_X * 0.5));
    let rot = turn_x(radians(p.tilt.x)) * turn_y(-radians(p.tilt.y)) * turn_z(-radians(p.tilt.z));
    // A wide frame makes the card (sideways at the start) taller than in a square one; push it down by the
    // extra height while it rises in, so it still starts fully below the frame.
    let extra = p.size * max(aspect - 1.0, 0.0) * abs(sin(radians(p.tilt.z))) * p.drop;
    let centre = vec3f(0.0, (p.lift - 0.5) * 2.0 - extra, -depth);
    let ax = rot * vec3f(p.size * aspect, 0.0, 0.0);
    let ay = rot * vec3f(0.0, p.size, 0.0);
    let ray = normalize(vec3f(ndc.x * aspect, ndc.y, -depth));
    let n = cross(ax, ay);
    let facing = -dot(ray, n);
    if (abs(facing) <= 1e-7) { return NO_HIT; }
    let reach = -dot(centre, n) / facing;
    if (reach <= 0.0) { return NO_HIT; }
    let rel = ray * reach - centre;
    let local = vec2f(dot(rel, ax) / dot(ax, ax), dot(rel, ay) / dot(ay, ay));
    return local * 0.5 + vec2f(0.5);
}

fn hash(a: f32, b: f32) -> f32 {
    let f = fract(vec2f(a, b) * 13.517);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

// The incoming clip with rounded corners (card uv, y up).
fn card_texel(q: vec2f, radius: f32) -> vec4f {
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return vec4f(0.0); }
    let px = (q - vec2f(0.5)) * globals.size;
    let half = 0.5 * globals.size;
    let r = radius * globals.size.x;
    let d = length(max(abs(px) - half + vec2f(r), vec2f(0.0))) - r;
    if (d > 0.0) { return vec4f(0.0); }
    return vec4f(textureSampleLevel(second, smp, vec2f(q.x, 1.0 - q.y), 0.0).rgb, 1.0);
}

fn track(s: f32, k: array<vec2f, 6>) -> vec2f {
    let f = s * 5.0;
    if (s <= 0.2) { return mix(k[0], k[1], f); }
    if (s <= 0.4) { return mix(k[1], k[2], f - 1.0); }
    if (s <= 0.6) { return mix(k[2], k[3], f - 2.0); }
    if (s <= 0.8) { return mix(k[3], k[4], f - 3.0); }
    return mix(k[4], k[5], f - 4.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let up = vec2f(uv.x, 1.0 - uv.y);
    let ndc = up * 2.0 - vec2f(1.0);
    let aspect = globals.size.x / globals.size.y;
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let radius = corner_at(t);
    let now = pose_at(t);
    let before = pose_at(t - FRAME);
    let smear = smear_at(t);
    if (abs(smear) < 0.001) {
        gpufx_write(id, card_texel(card_hit(ndc, now, aspect), radius));
        return;
    }
    // Six poses pushed forward along the frame-to-frame motion; the taps walk the path between them.
    var hits: array<vec2f, 6>;
    for (var i = 0; i < 6; i++) {
        let w = smear * f32(i) / 5.0 + 1.0;
        let p = Pose(mix(before.lift, now.lift, w), mix(before.size, now.size, w), mix(before.tilt, now.tilt, w), mix(before.drop, now.drop, w));
        hits[i] = card_hit(ndc, p, aspect);
    }
    var acc = vec4f(0.0);
    for (var k = 0.0; k < TAPS; k += 1.0) {
        let s = k / (TAPS - 1.0) + DITHER * (hash(k + up.x, k * up.y) - 0.5) / TAPS;
        acc += card_texel(track(s, hits), radius);
    }
    gpufx_write(id, acc / TAPS);
}
