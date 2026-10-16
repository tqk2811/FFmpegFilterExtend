// The picture punches in, snaps back, then tilts and wobbles in 3D around the cut to the second clip, smeared by a camera motion blur.
//
// `progress` 0..1 spans the scene time 0..SPAN (seconds). The frame is a textured plane
// (mirror tiled) seen through a 39.6 degree camera; its scale and its tilt around the x and z
// axes follow keyframed curves. The blur traces each pixel along the path the plane took
// over the last frame (extrapolated a little forward) and averages 15 dithered samples.

const SPAN: f32 = 1.99999; // a hair under 2 s, so the halfway frame still shows the first clip
// The second clip replaces the first at this time.
const T_CUT: f32 = 1.0;
// Motion before and after this range is at rest.
const T_MOVE_FROM: f32 = 0.4;
const T_MOVE_TO: f32 = 1.8;
const FRAME: f32 = 0.0333333;
const HALF_FOV_X: f32 = 0.34557519; // 19.8 degrees
const DEG: f32 = 0.017453293;
const SAMPLES: f32 = 15.0;
// Blur path: the sampled transforms span this range of the previous -> current frame mix.
const PATH_FROM: f32 = 0.58;
const PATH_LEN: f32 = 1.26;

fn cubic(p1: f32, p2: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * p1 * r * r * s + 3.0 * p2 * r * s * s + s * s * s;
}

// y(x) of the timing curve (0,0)-(k.x,k.y)-(k.z,k.w)-(1,1).
fn ease(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 14; n++) {
        let mid = (lo + hi) * 0.5;
        if (cubic(k.x, k.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return cubic(k.y, k.w, (lo + hi) * 0.5);
}

fn seg(t: f32, t0: f32, t1: f32, v0: f32, v1: f32, k: vec4f) -> f32 {
    return mix(v0, v1, ease(k, clamp((t - t0) / (t1 - t0), 0.0, 1.0)));
}

const SOFT = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);
const KICK = vec4f(0.3333333, 0.0, 0.6666667, 1.0);
const LEAD = vec4f(0.1666667, 0.1666667, 0.6666667, 1.0);
const SETTLE = vec4f(0.3333333, 0.0, 0.8333333, 0.8333333);

fn zoom_at(t: f32) -> f32 {
    if (t < 0.633333) { return seg(t, 0.433333, 0.633333, 1.0, 1.7, SOFT); }
    if (t < 0.7) { return seg(t, 0.633333, 0.7, 1.7, 1.77642105, SOFT); }
    if (t < 0.766667) { return seg(t, 0.7, 0.766667, 1.77642105, 1.25284211, SOFT); }
    if (t < 0.933333) { return seg(t, 0.766667, 0.933333, 1.25284211, 0.62, SOFT); }
    if (t < 1.0) { return seg(t, 0.933333, 1.0, 0.62, 1.601, SOFT); }
    return seg(t, 1.0, 1.766667, 1.601, 1.0, SOFT);
}

// Tilt around the horizontal axis, degrees.
fn pitch_at(t: f32) -> f32 {
    if (t < 0.966667) { return seg(t, 0.733333, 0.966667, 0.0, -19.0, LEAD); }
    if (t < 1.033333) { return seg(t, 0.966667, 1.033333, -19.0, 8.0, KICK); }
    if (t < 1.1) { return seg(t, 1.033333, 1.1, 8.0, -9.666667, KICK); }
    return seg(t, 1.1, 1.233333, -9.666667, 0.0, SETTLE);
}

// Roll around the view axis, degrees.
fn roll_at(t: f32) -> f32 {
    if (t < 1.033333) { return seg(t, 0.966667, 1.033333, 0.0, -3.5, KICK); }
    if (t < 1.1) { return seg(t, 1.033333, 1.1, -3.5, 7.0, KICK); }
    return seg(t, 1.1, 1.233333, 7.0, 0.0, SETTLE);
}

// Where the camera ray through `ndc` hits the transformed plane, in texture uv.
// `pose` = (scale, pitch, roll) in degrees.
fn plane_uv(ndc: vec2f, aspect: f32, pose: vec3f) -> vec2f {
    let dist = aspect / tan(HALF_FOV_X);
    let ray = vec3f(ndc.x * aspect, ndc.y, -dist);
    let a = pose.y * DEG;
    let b = -pose.z * DEG;
    let ca = cos(a);
    let sa = sin(a);
    let cb = cos(b);
    let sb = sin(b);
    // Plane normal: rotate (0,0,1) by roll then pitch.
    let normal = vec3f(0.0, -sa, ca);
    let centre = vec3f(0.0, 0.0, -dist);
    let denom = dot(normal, ray);
    if (abs(denom) < 1e-6) { return vec2f(-10.0); }
    let hit = ray * (dot(normal, centre) / denom) - centre;
    // Undo pitch, then roll.
    let p1 = vec3f(hit.x, ca * hit.y + sa * hit.z, -sa * hit.y + ca * hit.z);
    let p2 = vec2f(cb * p1.x + sb * p1.y, -sb * p1.x + cb * p1.y);
    let local = p2 / vec2f(pose.x * aspect, pose.x);
    return vec2f(local.x + 1.0, 1.0 - local.y) * 0.5;
}

fn fold(v: vec2f) -> vec2f {
    return abs(((v - 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
}

fn dither_hash(a: f32, b: f32) -> f32 {
    var f = fract(vec2f(a, b) * 13.517);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y);
}

fn pick(uv: vec2f, late: bool) -> vec4f {
    if (late) { return textureSampleLevel(second, smp, uv, 0.0); }
    return textureSampleLevel(first, smp, uv, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SPAN;
    let late = t >= T_CUT;
    if (t < T_MOVE_FROM || t > T_MOVE_TO) {
        gpufx_write(id, vec4f(pick(uv, late).rgb, 1.0));
        return;
    }
    let dims = globals.size;
    let aspect = dims.x / dims.y;
    let ndc = vec2f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let now = vec3f(zoom_at(t), pitch_at(t), roll_at(t));
    let tp = t - FRAME;
    let before = vec3f(zoom_at(tp), pitch_at(tp), roll_at(tp));

    // Six points along the motion path, from the previous frame's pose forward.
    var pts: array<vec2f, 6>;
    for (var i = 0; i < 6; i++) {
        let w = PATH_FROM + PATH_LEN * f32(i) / 5.0;
        pts[i] = plane_uv(ndc, aspect, mix(before, now, w));
    }

    let gl = vec2f(uv.x, 1.0 - uv.y);
    var acc = vec4f(0.0);
    for (var j = 0.0; j < SAMPLES; j += 1.0) {
        let s = j / (SAMPLES - 1.0) + (dither_hash(j + gl.x, j * gl.y) - 0.5) / SAMPLES;
        let x = s * 5.0;
        let k = clamp(i32(ceil(x) - 1.0), 0, 4);
        let q = mix(pts[k], pts[k + 1], x - f32(k));
        acc += pick(fold(q), late);
    }
    gpufx_write(id, vec4f((acc / SAMPLES).rgb, 1.0));
}
