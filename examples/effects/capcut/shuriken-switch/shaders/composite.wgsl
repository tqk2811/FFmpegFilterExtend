// The first clip spins away into the distance while the second flies in edge-on and untwists to fill the frame.

// Length of the animation timeline in seconds.
const SPAN: f32 = 1.0833333;
// Horizontal field of view of the virtual camera, in degrees.
const FOV_X: f32 = 39.5977527;
// Reference canvas size the motion was laid out on, in pixels.
const CANVAS: f32 = 1280.0;

// Cubic Bezier easing through (0,0), (c.x,c.y), (c.z,c.w), (1,1): bisect for x, return y.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Value animated from `a` to `b` between times t0 and t1 along the given curve.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    return mix(a, b, bezier_ease(clamp((t - t0) / (t1 - t0), 0.0, 1.0), c));
}

// A placed card: centre in canvas pixels (z away from the viewer), uniform scale in percent,
// tilt / turn / roll in degrees.
struct Card {
    pos: vec3f,
    scale: f32,
    angles: vec3f,
}

fn outgoing_card(t: f32) -> Card {
    let t0 = 0.208333;
    let t1 = 0.791667;
    var c: Card;
    c.pos = mix(vec3f(640.0, 640.0, 0.0), vec3f(1102.0, 640.0, 1553.0),
        keyed(t, t0, t1, 0.0, 1.0, vec4f(0.456722, 0.074306, 0.0, 1.0)));
    c.scale = keyed(t, t0, t1, 100.0, 0.0, vec4f(0.456722, 0.256039, 0.0, 1.0));
    c.angles = vec3f(
        keyed(t, t0, t1, 0.0, -9.0, vec4f(0.456722, -0.766605, 0.0, 1.0)),
        keyed(t, t0, t1, 0.0, -24.0, vec4f(0.456722, 1.200041, 0.0, 1.0)),
        keyed(t, t0, t1, 0.0, -150.0, vec4f(0.456722, 0.028602, 0.0, 1.0)));
    return c;
}

fn incoming_card(t: f32) -> Card {
    var c: Card;
    c.pos = mix(vec3f(92.0, 640.0, -339.0), vec3f(640.0, 640.0, 0.0),
        keyed(t, 0.208333, 1.041667, 0.0, 1.0, vec4f(0.342541, 0.375107, 0.0, 1.0)));
    if (t < 0.291667) {
        c.scale = 0.0;
    } else if (t < 0.333333) {
        c.scale = keyed(t, 0.291667, 0.333333, 0.0, 21.602440, vec4f(0.366674, 0.142337, 0.698622, 0.901550));
    } else if (t < 0.416667) {
        c.scale = keyed(t, 0.333333, 0.416667, 21.602440, 41.019434, vec4f(0.452333, 0.328785, 0.766937, 0.697600));
    } else {
        c.scale = keyed(t, 0.416667, 1.041667, 41.019434, 100.0, vec4f(0.229457, 0.710064, 0.0, 0.999999663));
    }
    if (t < 0.416667) {
        c.angles = vec3f(
            keyed(t, 0.208333, 0.416667, 17.0, 26.455243, vec4f(0.409059, -0.506803, 0.076243, 3.961356)),
            keyed(t, 0.208333, 0.416667, 84.0, 69.479417, vec4f(0.409059, 0.594113, 0.111602, -1.913635)),
            keyed(t, 0.208333, 0.416667, -38.0, 20.125848, vec4f(0.654520, 0.202383, 0.0, 0.690792)));
    } else {
        c.angles = vec3f(
            keyed(t, 0.416667, 1.041667, 26.455243, 0.0, vec4f(0.040516, 0.140949, 0.172007, 1.000000194)),
            keyed(t, 0.416667, 1.041667, 69.479417, 0.0, vec4f(0.040516, 0.086035, 0.154374, 1.000000012)),
            keyed(t, 0.416667, 1.041667, 20.125848, 0.0, vec4f(0.144944, -0.367030, 0.413989, 1.0)));
    }
    return c;
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

// Cast the pixel's view ray onto the card and return the card texture coordinate (outside 0..1 = miss).
// Scene space is y-up with the camera at the origin looking down -z; the frame spans
// x in [-aspect, aspect] and y in [-1, 1] at the card's rest depth.
fn card_uv(c: Card, ndc: vec2f, aspect: f32) -> vec2f {
    if (c.scale <= 0.0) { return vec2f(-1.0); }
    let dist = aspect / tan(radians(FOV_X * 0.5));
    let unit = 2.0 * aspect / CANVAS;
    let centre = vec3f((c.pos.x - 640.0) * unit, (640.0 - c.pos.y) * 2.0 / CANVAS, -dist - c.pos.z * unit);
    let r = turn_x(radians(c.angles.x)) * turn_y(radians(-c.angles.y)) * turn_z(radians(-c.angles.z));
    let normal = r * vec3f(0.0, 0.0, 1.0);
    let ray = vec3f(ndc.x * aspect / dist, ndc.y / dist, -1.0);
    let denom = dot(normal, ray);
    if (abs(denom) < 1e-6) { return vec2f(-1.0); }
    let hit = dot(normal, centre) / denom;
    if (hit <= 0.0) { return vec2f(-1.0); }
    let local = transpose(r) * (ray * hit - centre) / (c.scale / 100.0);
    return vec2f(local.x / aspect * 0.5 + 0.5, 0.5 - local.y * 0.5);
}

fn inside(p: vec2f) -> bool { return all(p >= vec2f(0.0)) && all(p <= vec2f(1.0)); }

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so the cut into and out of the transition is seamless.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SPAN;
    let dims = globals.size;
    let aspect = dims.x / dims.y;
    let ndc = vec2f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);

    // Black stage, the outgoing card, then the incoming card laid over it.
    var colour = vec3f(0.0);
    let pa = card_uv(outgoing_card(t), ndc, aspect);
    if (inside(pa)) {
        let a = textureSampleLevel(spun, smp, pa, 0.0);
        colour = a.rgb;
    }
    let pb = card_uv(incoming_card(t), ndc, aspect);
    if (inside(pb)) {
        let b = textureSampleLevel(zoomed, smp, pb, 0.0);
        colour = colour * (1.0 - b.a) + b.rgb;
    }
    gpufx_write(id, vec4f(colour, 1.0));
}
