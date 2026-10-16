// The second clip swings down from a hinge on the top edge, in perspective with motion blur, over the shrinking, zoom-blurred first clip.

// The whole transition spans this many seconds of animation time.
const SPAN: f32 = 0.83333;
// Horizontal field of view of the virtual camera, in degrees.
const FOV_X: f32 = 39.6;
// Number of sub-frames averaged for the falling clip's motion blur.
const SWING_TAPS: i32 = 24;
// Strongest zoom blur on the first clip (fraction of the distance to the centre).
const ZOOM_MAX: f32 = 0.085;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * x1 + 3.0 * inv * s * s * x2 + s * s * s;
        let dx = 3.0 * inv * inv * x1 + 6.0 * inv * s * (x2 - x1) + 3.0 * s * s * (1.0 - x2);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * y1 + 3.0 * inv * s * s * y2 + s * s * s;
}

// Value animated from `a` to `b` between times t0 and t1 with the given easing curve.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, curve: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, curve.x, curve.y, curve.z, curve.w));
}

// Hinge angle (degrees) of the falling clip; `lag` delays the curve for the blur trail.
fn hinge_angle(t: f32, lag: f32) -> f32 {
    return keyed(t, 0.1 + lag, 0.6 + lag, -90.0, 0.0, vec4f(0.33333, 0.0, 0.66667, 1.0));
}

// Mirror coordinates outside [0, 1] back inside, so the shrunken first clip tiles mirrored.
fn mirror(p: vec2f) -> vec2f {
    let m = abs(p - 2.0 * floor((p + 1.0) * 0.5));
    return clamp(m, vec2f(0.0), vec2f(1.0));
}

// First clip: scaled about the centre (mirror-filled edges), with a one-sided zoom blur
// that pulls samples toward the centre.
fn first_layer(uv: vec2f, t: f32) -> vec3f {
    let scale = keyed(t, 0.0, 0.4, 1.0, 0.87, vec4f(0.28527, 0.10034, 0.66667, 1.0));
    let p = 0.5 + (uv - 0.5) / scale;
    let strength = keyed(t, 0.0, 0.36667, 0.0, ZOOM_MAX, vec4f(0.16667, 0.16667, 0.83333, 0.83333));
    // The blur runs on a canvas grown by 0.35 per side, hence the 1.7 for the tap count.
    let reach = (p - 0.5) * strength;
    let taps = min(160.0 * (0.9 * length(reach) / 1.7 + 0.1) + 5.0, 128.0);
    let stride = reach / taps;
    var acc = textureSampleLevel(first, smp, mirror(p), 0.0).rgb;
    var count = 1.0;
    for (var k = 1; k <= 128; k++) {
        if (f32(k) > taps) { break; }
        acc += textureSampleLevel(first, smp, mirror(p - stride * f32(k)), 0.0).rgb;
        count += 1.0;
    }
    return acc / count;
}

// Second clip as a card hinged at the top edge, rotated `angle` degrees about the
// horizontal axis and seen by a pinhole camera. Returns premultiplied colour + coverage.
fn swing_sample(ndc: vec2f, ratio: f32, depth: f32, angle: f32) -> vec4f {
    let a = radians(angle);
    let axis_y = vec3f(0.0, cos(a), sin(a));
    let normal = vec3f(0.0, -sin(a), cos(a));
    let hinge = vec3f(0.0, 1.0073, -depth);
    let ray = vec3f(ndc.x * ratio, ndc.y, -depth);
    let facing = dot(normal, ray);
    if (abs(facing) < 1e-6) { return vec4f(0.0); }
    let dist = dot(normal, hinge) / facing;
    if (dist <= 0.0) { return vec4f(0.0); }
    let q = ray * dist - hinge;
    // Card centre sits 1.0042 below the hinge; the card is 2 * ratio wide and 2 tall.
    let tx = (q.x / ratio - 0.00208 + 1.0) * 0.5;
    let ty = (dot(q, axis_y) + 1.0042 + 1.0) * 0.5;
    let tc = vec2f(tx, 1.0 - ty);
    if (any(tc < vec2f(0.0)) || any(tc > vec2f(1.0))) { return vec4f(0.0); }
    return vec4f(textureSampleLevel(second, smp, tc, 0.0).rgb, 1.0);
}

fn second_layer(uv: vec2f, t: f32) -> vec4f {
    if (t < 0.1) { return vec4f(0.0); }
    // A slight top-anchored zoom that settles while the card lands.
    let settle = keyed(t, 0.16667, 0.83333, 1.05, 1.002, vec4f(0.33333, 0.0, 0.56483, 0.9956));
    let p = vec2f(0.5 + (uv.x - 0.5) / settle, uv.y / settle);
    if (any(p < vec2f(0.0)) || any(p > vec2f(1.0))) { return vec4f(0.0); }
    let ratio = globals.size.x * globals.pixel_aspect / globals.size.y;
    let depth = ratio / tan(radians(FOV_X * 0.5));
    let ndc = vec2f(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0);
    let now = hinge_angle(t, 0.0);
    let before = hinge_angle(t, 0.03333);
    var acc = vec4f(0.0);
    for (var k = 0; k < SWING_TAPS; k++) {
        let w = 0.75 + 0.45 * f32(k) / f32(SWING_TAPS - 1);
        acc += swing_sample(ndc, ratio, depth, mix(before, now, w));
    }
    return acc / f32(SWING_TAPS);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let back = first_layer(uv, t);
    let card = second_layer(uv, t);
    gpufx_write(id, vec4f(card.rgb + back * (1.0 - card.a), 1.0));
}
