// Snap zoom, step 1: the first clip shrinks into a pinched, magnified bubble, then the second snaps out of a bulge with a small shake.

const SPAN: f32 = 0.9333333;
const HANDOFF: f32 = 0.5333333;
// The cut itself lands half a 30 fps frame after the keys finish, so the frame sampled right at
// HANDOFF still shows the fully shrunk first clip under the flash, as CapCut does.
const CUT: f32 = 0.55;
const PI: f32 = 3.1415927;

// Cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1): find the curve parameter for `u` by halving, return its height.
fn curve(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(c: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (curve(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return curve(c.y, c.w, 0.5 * (lo + hi));
}

// One animated stretch: before `t0` keep `prev`, inside ease from v0 to v1, afterwards hold v1.
fn seg(prev: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, c: vec4f) -> f32 {
    if (t < t0) { return prev; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(c, (t - t0) / (t1 - t0)));
}

fn seg2(prev: vec2f, t: f32, t0: f32, t1: f32, v0: vec2f, v1: vec2f, c: vec4f) -> vec2f {
    if (t < t0) { return prev; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(c, (t - t0) / (t1 - t0)));
}

fn fold(x: vec2f) -> vec2f {
    let m = x - 1.0;
    return abs(m - 2.0 * floor(m * 0.5) - 1.0);
}

fn inside(uv: vec2f) -> bool {
    return all(uv >= vec2f(0.0)) && all(uv <= vec2f(1.0));
}

// Lens squeeze: the picture is pulled towards the middle by up to 75 % (bend < 0) or pushed out by 90 % (bend > 0),
// fading to nothing at the frame border. Undo it for one screen point by halving along the ray from the middle.
fn squeeze_factor(q: vec2f, bend: f32) -> f32 {
    let w = abs(bend) * cos(0.5 * PI * q.x) * cos(0.5 * PI * q.y);
    if (bend > 0.0) { return mix(1.0, 1.9, w); }
    return mix(1.0, 0.25, w);
}

fn unsqueeze(uv: vec2f, bend: f32) -> vec2f {
    if (abs(bend) < 1e-5) { return uv; }
    let p = uv * 2.0 - 1.0;
    let reach = max(abs(p.x), abs(p.y));
    if (reach < 1e-6) { return uv; }
    let rim = p / reach;
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (mid * squeeze_factor(rim * mid, bend) > reach) { hi = mid; } else { lo = mid; }
    }
    return rim * (0.5 * (lo + hi)) * 0.5 + 0.5;
}

// Pincushion lens set by a field of view in degrees (0 = none): samples closer to the middle the further out the pixel is.
fn pincushion(uv: vec2f, fov: f32) -> vec2f {
    let f = clamp(fov / 180.0, 0.0, 1.0);
    if (f <= 0.0) { return uv; }
    let k1 = 14.77 * pow(f, 10.0) + 2.7 * f * f * f;
    let k2 = 3.82 * pow(f, 2.54) + 0.529 * f;
    let d = uv - 0.5;
    let r = length(vec2f(d.x, d.y * globals.size.y / globals.size.x));
    return 0.5 + d / (1.0 + k1 * r + k2 * r * r);
}

fn outgoing(uv: vec2f, t: f32) -> vec3f {
    var size = seg(100.0, t, 0.0, 0.4333333, 100.0, 43.0, vec4f(1.0, 1.75e-7, 0.6666667, 1.0));
    size = seg(size, t, 0.4333333, HANDOFF, 43.0, 84.0, vec4f(0.1666667, 0.0, 0.5833333, 0.5));
    var bend = seg(0.0, t, 0.0, 0.4333333, 0.0, -38.0, vec4f(1.0, 1.4e-8, 0.965286, 1.0));
    bend = seg(bend, t, 0.4333333, HANDOFF, -38.0, -63.909477, vec4f(0.2966946, 0.0, 0.6594099, 0.4739525));
    var fov = seg(0.0, t, 0.0, 0.4333333, 0.0, 128.0, vec4f(1.0, 1.64e-7, 0.9267915, 1.0));
    fov = seg(fov, t, 0.4333333, HANDOFF, 128.0, 128.60358, vec4f(0.4683125, -1.788e-6, 0.782728, 0.7028359));

    let lensed = pincushion(uv, fov);
    if (!inside(lensed)) { return vec3f(0.0); }
    let bent = unsqueeze(lensed, bend * 0.01);
    let src = fold((bent - 0.5) / (size * 0.01) + 0.5);
    return textureSampleLevel(first, smp, src, 0.0).rgb;
}

fn incoming(uv: vec2f, t: f32) -> vec3f {
    let size = seg(77.0, t, HANDOFF, 0.6333333, 77.0, 100.0, vec4f(0.3333333, 0.0, 0.6666667, 1.0));
    let bend = seg(-100.0, t, HANDOFF, 0.7, -100.0, 0.0, vec4f(0.0001, 0.0, 0.2539385, 0.990722));
    let fov = seg(85.0, t, HANDOFF, 0.7, 85.0, 0.0, vec4f(0.0001, 0.0, 0.2539385, 1.0109153));

    // Short shake of the layer centre, in pixels of a 1280 px square layout.
    let wobble = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);
    let k0 = vec2f(640.0, 616.0);
    let k1 = vec2f(657.8125, 613.18557);
    let k2 = vec2f(620.30738, 631.65973);
    let k3 = vec2f(646.15649, 630.35443);
    let k4 = vec2f(636.3041, 635.67044);
    let k5 = vec2f(641.21239, 637.33471);
    let k6 = vec2f(640.0, 640.0);
    var at = seg2(k0, t, HANDOFF, 0.5833333, k0, k1, wobble);
    at = seg2(at, t, 0.5833333, 0.6333333, k1, k2, wobble);
    at = seg2(at, t, 0.6333333, 0.6833333, k2, k3, wobble);
    at = seg2(at, t, 0.6833333, 0.7333333, k3, k4, wobble);
    at = seg2(at, t, 0.7333333, 0.7833333, k4, k5, wobble);
    at = seg2(at, t, 0.7833333, 0.8333333, k5, k6, wobble);
    let shift = (at - vec2f(640.0)) / 1280.0;

    let lensed = pincushion(uv, fov);
    if (!inside(lensed)) { return vec3f(0.0); }
    let bent = unsqueeze(lensed, bend * 0.01);
    let src = fold((bent - shift - 0.5) / (size * 0.01) + 0.5);
    return textureSampleLevel(second, smp, src, 0.0).rgb;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    var c: vec3f;
    if (t < CUT) { c = outgoing(uv, t); } else { c = incoming(uv, t); }
    gpufx_write(id, vec4f(c, 1.0));
}
