// Snapshot glam, step 2: a short dithered zoom blur toward the centre as the second clip lands.

const SPAN: f32 = 1.0;

fn tap_jitter(p: vec2f) -> f32 {
    let f = fract(p * 13.517);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

// Blur strength (slider units): a near-linear rise to 60 and back.
fn amount_now(t: f32) -> f32 {
    if (t < 0.6 || t >= 0.733333) { return 0.0; }
    if (t < 0.666667) { return 60.0 * (t - 0.6) / 0.066667; }
    return 60.0 * (0.733333 - t) / 0.066666;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let strength = amount_now(t) / 200.0;
    var acc = textureSampleLevel(scene, smp, uv, 0.0).rgb;
    if (strength > 0.0) {
        // Work in bottom-up texture space so the dither pattern lines up.
        let p = vec2f(uv.x, 1.0 - uv.y);
        let reach = (p - vec2f(0.5)) * strength;
        let taps = min(8.0 * 0.2 * (0.9 * length(reach) + 0.1) + 5.0, 128.0);
        let stride = reach / taps;
        let start = p + stride * (0.5 * (tap_jitter(p) * 2.0 - 1.0));
        var total = 1.0;
        for (var k = 1.0; k <= 128.0; k += 1.0) {
            if (k > taps) { break; }
            let q = start - stride * k;
            total += 1.0;
            // Taps that leave the frame count as black.
            if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
                acc += textureSampleLevel(scene, smp, vec2f(q.x, 1.0 - q.y), 0.0).rgb;
            }
        }
        acc /= total;
    }
    gpufx_write(id, vec4f(acc, 1.0));
}
