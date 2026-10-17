// Snap zoom, step 3: radial zoom streaks towards the centre, then a two-frame bluish flash at the hand-off.

const SPAN: f32 = 0.9333333;

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

fn streaks(uv: vec2f, amount: f32) -> vec3f {
    let base = textureSampleLevel(trail, smp, uv, 0.0).rgb;
    if (amount <= 0.0) { return base; }
    let reach = (uv - 0.5) * (amount / 200.0);
    let n = min(750.0 * (0.9 * length(reach) + 0.1) + 20.0, 256.0);
    let step_uv = reach / n;
    var sum = base;
    var weight = 1.0;
    for (var k = 1.0; k <= n; k += 1.0) {
        let p = uv - k * step_uv;
        // Samples falling off the frame count as black.
        if (all(p >= vec2f(0.0)) && all(p <= vec2f(1.0))) {
            sum += textureSampleLevel(trail, smp, p, 0.0).rgb;
        }
        weight += 1.0;
    }
    return sum / weight;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;

    let smooth_in = vec4f(0.3333333, 0.0, 0.6666667, 1.0);
    var amount = seg(0.0, t, 0.2333333, 0.3666667, 0.0, 28.0, smooth_in);
    amount = seg(amount, t, 0.3666667, 0.5333333, 28.0, 0.0, vec4f(0.3333333, 0.0, 0.8333333, 1.0));
    var c = streaks(uv, amount);

    // Flash: a light blue wash up to the cut (0.55, see scene.wgsl), then a fainter one for one
    // 30 fps frame; time spans, so any progress sampling lands on them.
    if (t >= 0.5 && t < 0.55) {
        c += vec3f(195.0, 207.0, 255.0) / 255.0 * (85.0 / 255.0);
    } else if (t >= 0.55 && t < 0.5833333) {
        c += vec3f(102.0, 132.0, 255.0) / 255.0 * (22.0 / 255.0);
    }
    gpufx_write(id, vec4f(c, 1.0));
}
