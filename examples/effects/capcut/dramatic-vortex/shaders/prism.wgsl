// Dramatic vortex, step 2: a twisting prism blur that splits the colours around the spin.

// Timeline of the animation: 0.366667 s to 1.3 s; the second clip takes over just after 0.833333 s.
const START: f32 = 0.366667;
const TIMELINE: f32 = 0.933333;
const SWITCH_AT: f32 = 0.8334;

fn timeline_now() -> f32 { return START + clamp(params.progress, 0.0, 1.0) * TIMELINE; }

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

// One keyframe segment: keeps `cur` before `t0`, eases from v0 to v1 inside, holds v1 after.
fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, e: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(e.x, e.y, e.z, e.w, (t - t0) / (t1 - t0)));
}

const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

fn mirror01(q: vec2f) -> vec2f {
    return abs(((q - 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
}

// ---- Prism: a zoom (and twist) blur whose taps are tinted along a colour ramp, splitting RGB apart ----

struct Prism {
    amount: f32,      // 0..1: how much of the zoom/twist applies
    scale_a: f32,     // zoom at the start of the tap run (1 = none)
    scale_b: f32,     // zoom at its end
    angle_a: f32,     // twist (radians) at the start
    angle_b: f32,     // twist at the end
    falloff: f32,     // brightens the far taps (+) or the near ones (-)
    color_a: vec3f,
    color_m: vec3f,
    color_b: vec3f,
};

fn turn_about(p: vec2f, c: vec2f, a: f32) -> vec2f {
    let aspect = globals.size.x / globals.size.y;
    var d = p - c;
    d.x *= aspect;
    let s = sin(a);
    let k = cos(a);
    d = vec2f(d.x * k - d.y * s, d.x * s + d.y * k);
    d.x /= aspect;
    return d + c;
}

fn ramp(pr: Prism, x: f32) -> vec3f {
    let wa = clamp(1.0 - abs(x) / 0.5, 0.0, 1.0);
    let wm = clamp(1.0 - abs(x - 0.5) / 0.5, 0.0, 1.0);
    let wb = clamp(1.0 - abs(x - 1.0) / 0.5, 0.0, 1.0);
    return pr.color_a * wa + pr.color_m * wm + pr.color_b * wb;
}

fn prism(tex: texture_2d<f32>, uv: vec2f, pr: Prism) -> vec4f {
    let centre = vec2f(0.5);
    let spread = pr.scale_b - pr.scale_a;
    var taps = max(80.0 * abs(spread), 79.0 * abs(pr.angle_b - pr.angle_a) / 0.5);
    taps = floor(max(taps * sqrt(length(uv - centre)) * 4.0, 6.0));
    let step_angle = (pr.angle_b - pr.angle_a) * pr.amount / taps;
    var cur = turn_about(uv, centre, pr.angle_a * pr.amount);
    let za = mix(1.0, pr.scale_a, pr.amount);
    let zb = mix(1.0, pr.scale_b, pr.amount);
    var lit = vec4f(0.0);
    var norm = vec4f(0.0);
    for (var k = 0.0; k <= 1024.0; k += 1.0) {
        if (k > taps) { break; }
        let f = k / taps;
        let d = cur - centre;
        cur = turn_about(cur, centre, step_angle);
        var shade: f32;
        if (pr.scale_a > pr.scale_b) {
            shade = pow(clamp(1.0 - f, 0.001, 1.0), 1.0 + (pr.scale_a - pr.scale_b) * 2.0);
        } else {
            shade = pow(clamp(f, 0.001, 1.0), 1.0 + spread * 2.0);
        }
        let tint = vec4f(ramp(pr, 1.0 - f) * shade, 1.0);
        let q = mirror01(mix(d / za + centre, d / zb + centre, f));
        let c = textureSampleLevel(tex, smp, q, 0.0);
        lit += c * tint * vec4f(vec3f(mix(1.0 - pr.falloff, 1.0 + pr.falloff, f)), 1.0);
        norm += tint;
    }
    return lit / norm;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = timeline_now();
    var amount = key(0.0, t, 0.566667, 0.733333, 0.0, 100.0, vec4f(0.3333333, 0.0, 0.0, 1.0));
    amount = key(amount, t, 0.733333, 1.266667, 100.0, 0.0, vec4f(0.3333333, 0.0, 0.0, 1.0));
    let uv = gpufx_uv(id);
    var c = textureSampleLevel(spun, smp, uv, 0.0);
    if (amount > 0.0) {
        var zoom_end = key(98.0, t, 0.633333, 0.833333, 98.0, 81.0, vec4f(0.3333333, 0.0, 0.6666667, 1.0));
        zoom_end = key(zoom_end, t, 0.833333, 1.266667, 81.0, 98.0, vec4f(0.3333333, 0.0, 0.0, 1.01118856));
        var twist_end = key(-4.0, t, 0.633333, 0.833333, -4.0, -23.0, vec4f(0.3333333, 0.0, 0.6666667, 1.0));
        twist_end = key(twist_end, t, 0.833333, 1.266667, -23.0, -4.0, vec4f(0.3333333, 0.0, 0.477812196, 0.983991912));
        var fall = key(0.0, t, 0.633333, 0.733333, 0.0, 4.0, vec4f(0.3333333, 0.0, 0.6666667, 1.0));
        fall = key(fall, t, 0.733333, 1.266667, 4.0, 0.0, vec4f(0.3333333, 0.0, 0.6666667, 1.0));
        let pr = Prism(amount / 100.0, 1.02, zoom_end / 100.0, 0.0, radians(twist_end), fall / 100.0,
                       vec3f(1.0, 0.0, 0.0), vec3f(0.0, 1.0, 0.0), vec3f(0.0, 0.0, 1.0));
        c = prism(spun, uv, pr);
    }
    gpufx_write(id, vec4f(c.rgb, 1.0));
}
