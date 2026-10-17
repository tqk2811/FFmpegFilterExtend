// Snap zoom, step 2: zoom smear that averages the picture over the last frame's change of scale.

const SPAN: f32 = 0.9333333;
const BLUR_END: f32 = 0.8333333;
const LAG: f32 = 0.0333333;

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

fn seg(prev: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, c: vec4f) -> f32 {
    if (t < t0) { return prev; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(c, (t - t0) / (t1 - t0)));
}

const SMOOTH = vec4f(0.3333333, 0.0, 0.6666667, 1.0);

// Zoom pulse 1 -> 1.2 -> 1 around the hand-off.
fn zoom_at(t: f32) -> f32 {
    let z = seg(1.0, t, 0.3333333, 0.5333333, 1.0, 1.2, SMOOTH);
    return seg(z, t, 0.5333333, 0.7, 1.2, 1.0, SMOOTH);
}

// How far along the frame-to-frame scale change the smear reaches.
fn reach_at(t: f32) -> f32 {
    let v = seg(0.5, t, 0.1666667, 0.2333333, 0.5, 2.0, vec4f(0.3333333, 0.0, 0.0, 0.5579597));
    return seg(v, t, 0.5333333, 0.7, 2.0, 0.0, SMOOTH);
}

fn fold(x: vec2f) -> vec2f {
    let m = x - 1.0;
    return abs(m - 2.0 * floor(m * 0.5) - 1.0);
}

fn jitter(a: f32, b: f32) -> f32 {
    var q = fract(vec2f(a, b) * 13.517);
    q += dot(q, q.yx + 22.541);
    return fract((q.x + q.y) * q.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let now = zoom_at(t);
    let before = zoom_at(t - LAG);
    if (t >= BLUR_END || abs(now - before) < 1e-6) {
        gpufx_write(id, textureSampleLevel(scene, smp, uv, 0.0));
        return;
    }
    let reach = reach_at(t);
    // Six scale keys spread along the smear, sampled piecewise-linearly.
    var keys: array<vec2f, 6>;
    for (var k = 0; k < 6; k++) {
        let w = reach * f32(k) / 5.0 + 0.75;
        let s = mix(before, now, w);
        keys[k] = (uv - 0.5) / s + 0.5;
    }
    let lo_n = 12.0;
    let hi_n = 24.0;
    let n = floor(lo_n + (hi_n - lo_n) * smoothstep(0.0, 0.2, length(keys[5] - keys[0])));
    var acc = vec4f(0.0);
    for (var i = 0.0; i < n; i += 1.0) {
        var w = i / (n - 1.0);
        w += (jitter(i + uv.x, i * uv.y) - 0.5) / n;
        let f = w * 5.0;
        let j = clamp(i32(floor(f)), 0, 4);
        let p = fold(mix(keys[j], keys[j + 1], f - f32(j)));
        acc += textureSampleLevel(scene, smp, p, 0.0);
    }
    gpufx_write(id, acc / n);
}
