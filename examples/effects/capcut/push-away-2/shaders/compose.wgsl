// Push Away 2, pass 1: the first clip pinches, shrinks and turns clockwise; the second clip arrives bulged, enlarged and turned back, both with a small camera shake.
//
// The scene clock runs from 0 to SPAN seconds over `progress`. Every animated value is a
// cubic Bezier ease between two keys, like a motion-graphics timeline.

const SPAN: f32 = 1.110011;
// Scene time at which the second clip replaces the first.
const SWAP: f32 = 0.540005;

// Bezier ease with control points (0,0), (c.x,c.y), (c.z,c.w), (1,1); x is solved by bisection.
fn ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let s = 0.5 * (lo + hi);
        let r = 1.0 - s;
        let bx = 3.0 * r * r * s * c.x + 3.0 * r * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * c.y + 3.0 * r * s * s * c.w + s * s * s;
}

// Value going from a to b between scene times t0 and t1; held outside that span.
fn key(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return a; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

fn cubic2(p0: vec2f, p1: vec2f, p2: vec2f, p3: vec2f, s: f32) -> vec2f {
    let r = 1.0 - s;
    return p0 * r * r * r + p1 * 3.0 * r * r * s + p2 * 3.0 * r * s * s + p3 * s * s * s;
}

// Point at fraction `f` of the arc length of a cubic path (32-step length table).
fn along_path(p0: vec2f, p1: vec2f, p2: vec2f, p3: vec2f, f: f32) -> vec2f {
    var total = 0.0;
    var prev = p0;
    for (var i = 1; i <= 32; i++) {
        let p = cubic2(p0, p1, p2, p3, f32(i) / 32.0);
        total += length(p - prev);
        prev = p;
    }
    let goal = clamp(f, 0.0, 1.0) * total;
    var run = 0.0;
    prev = p0;
    for (var i = 1; i <= 32; i++) {
        let p = cubic2(p0, p1, p2, p3, f32(i) / 32.0);
        let d = length(p - prev);
        if (run + d >= goal) {
            let w = select((goal - run) / d, 0.0, d <= 0.0);
            return cubic2(p0, p1, p2, p3, (f32(i) - 1.0 + w) / 32.0);
        }
        run += d;
        prev = p;
    }
    return p3;
}

// One leg of the shake: eased progress along a curved path between two points.
fn shake_leg(t: f32, t0: f32, t1: f32, c: vec4f, a: vec2f, b: vec2f, ta: vec2f, tb: vec2f) -> vec2f {
    return along_path(a, ta, tb, b, ease((t - t0) / (t1 - t0), c));
}

// Camera shake as a picture offset in 1080-pixel units.
fn shake(t: f32) -> vec2f {
    let rest = vec2f(540.0625, 540.0);
    let k1 = vec2f(531.28125, 543.9375);
    let k2 = vec2f(540.932487843, 535.871307312);
    let k3 = vec2f(538.85538316, 540.890548021);
    let k4 = vec2f(541.792224564, 539.62579811);
    let k5 = vec2f(540.844397734, 540.552943044);
    var p = rest;
    if (t >= 0.240002 && t < 0.390004) {
        p = shake_leg(t, 0.240002, 0.390004, vec4f(0.333333, 0.0, 0.622222, 0.820002), rest, k1,
            vec2f(537.6875, 538.28125), vec2f(531.303534112871, 542.988233566284));
    } else if (t >= 0.390004 && t < 0.510005) {
        p = shake_leg(t, 0.390004, 0.510005, vec4f(0.158525, 0.045065, 0.555975, 0.861665), k1, k2,
            vec2f(531.258965887129, 544.886766433716), vec2f(544.181002495252, 536.203494636762));
    } else if (t >= 0.510005 && t < 0.600006) {
        p = shake_leg(t, 0.510005, 0.600006, vec4f(0.106048, 0.058656, 0.476911, 0.696046), k2, k3,
            vec2f(539.607990143262, 535.735866530287), vec2f(538.458811017161, 540.099315673512));
    } else if (t >= 0.600006 && t < 0.690007) {
        p = shake_leg(t, 0.600006, 0.690007, vec4f(0.278718, 0.276646, 0.626586, 0.633637), k3, k4,
            vec2f(539.251955302839, 541.681780368488), vec2f(541.365695633336, 539.564091567031));
    } else if (t >= 0.690007 && t < 0.780008) {
        p = shake_leg(t, 0.690007, 0.780008, vec4f(0.090825, 0.189732, 0.523059, 0.0), k4, k5,
            vec2f(542.218753494664, 539.687504652969), vec2f(541.509804616763, 540.429879509502));
    } else if (t >= 0.780008 && t < 0.900009) {
        p = shake_leg(t, 0.780008, 0.900009, vec4f(0.24036, 1.0, 0.660332, 1.0), k5, rest,
            vec2f(540.178990851237, 540.676006578498), vec2f(540.067125572357, 539.997079481604));
    }
    return p - rest;
}

// Mirror-tile coordinates so the picture repeats reflected beyond its edges.
fn mirror_tile(p: vec2f) -> vec2f {
    let m = p - 1.0;
    return abs(m - 2.0 * floor(m * 0.5) - 1.0);
}

// The warp moves each point p (in -1..1) to p * s(p), with s peaking in the frame centre.
// Undo it along the ray through q by bisection on the radial factor.
fn unwarp(q: vec2f, bend: f32) -> vec2f {
    if (abs(bend) <= 0.00001) { return q; }
    let peak = select(1.9, 0.25, bend < 0.0);
    var lo = 1.0 / max(1.0, peak);
    var hi = 1.0 / min(1.0, peak);
    for (var i = 0; i < 18; i++) {
        let l = 0.5 * (lo + hi);
        let p = q * l;
        let t = p * 0.5 + 0.5;
        let r = sin(t.x * 3.14159265) * sin(t.y * 3.14159265);
        let f = l * mix(1.0, peak, abs(bend) * r);
        if (f > 1.0) { hi = l; } else { lo = l; }
    }
    return q * 0.5 * (lo + hi);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = params.progress * SPAN;
    let use_second = t >= SWAP;

    var bend: f32;
    var zoom: f32;
    var turn: f32;
    if (!use_second) {
        bend = key(t, 0.180002, 0.540005, 0.0, -25.0, vec4f(0.33333333, 0.0, 0.66666667, 1.0)) / 100.0;
        zoom = key(t, 0.180002, 0.540005, 100.0, 25.0, vec4f(1.0, 0.0, 0.9999, 1.000000093)) / 100.0;
        turn = key(t, 0.360004, 0.540005, 0.0, 15.0, vec4f(1.0, 0.0, 0.897777793, 1.000883077));
    } else {
        bend = key(t, 0.540005, 0.720007, 60.0, 0.0, vec4f(0.12592581, 0.005077016, 0.0, 0.987194805)) / 100.0;
        zoom = key(t, 0.540005, 0.780008, 121.0, 100.0, vec4f(0.20750752, -0.000359795, 0.0, 1.000242223)) / 100.0;
        turn = key(t, 0.540005, 0.720007, -32.0, 0.0, vec4f(0.230072627, -0.003472043, 0.0, 1.0));
    }

    // Layer centre: frame centre plus the shake, with the tiny constant offset of the rig.
    let centre = vec2f(0.5) + (shake(t) - vec2f(0.0625, 0.0)) / 1080.0;
    let aspect = globals.size.x / globals.size.y;
    var d = (uv - centre) * vec2f(aspect, 1.0);
    let a = -radians(turn);
    d = vec2f(cos(a) * d.x - sin(a) * d.y, sin(a) * d.x + cos(a) * d.y) / zoom;
    let layer_uv = mirror_tile(vec2f(0.5) + d / vec2f(aspect, 1.0));

    let src_uv = unwarp(layer_uv * 2.0 - 1.0, bend) * 0.5 + 0.5;
    var c: vec4f;
    if (use_second) {
        c = textureSampleLevel(second, smp, src_uv, 0.0);
    } else {
        c = textureSampleLevel(first, smp, src_uv, 0.0);
    }
    gpufx_write(id, vec4f(c.rgb, 1.0));
}
