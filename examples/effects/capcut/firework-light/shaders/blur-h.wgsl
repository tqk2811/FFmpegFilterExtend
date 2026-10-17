// Firework Light, pass 3: horizontal Gaussian pre-blur that softens the picture before the bokeh pass.

const SPAN: f32 = 2.0;

// Blur amount over time: 0 until 1/6 s, up to 35 at 1 s, back to 0 at 11/6 s.
fn blur_amount(t: f32) -> f32 {
    if (t <= 0.16666667 || t >= 1.83333333) { return 0.0; }
    if (t < 1.0) { return 35.0 * (t - 0.16666667) / 0.83333333; }
    return 35.0 * (1.83333333 - t) / 0.83333333;
}

fn weight(x: f32) -> f32 {
    return exp(-0.5 * x * x / 16.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let amount = blur_amount(params.progress * SPAN);
    // Tap count grows with the blur; one tap is one pixel of a 720-pixel short side.
    let taps = 22.0 * pow(amount / 79.0, 0.35) * 0.7;
    let step = vec2f(1.0, 0.0) / (globals.size / min(globals.size.x, globals.size.y) * 720.0);
    var sum = textureSampleLevel(soft_v, smp, uv, 0.0);
    var total = 1.0;
    for (var i = 1; i <= 64; i++) {
        if (f32(i) > taps) { break; }
        let w = weight(f32(i) / taps * 15.0);
        sum += (textureSampleLevel(soft_v, smp, uv + step * f32(i), 0.0) + textureSampleLevel(soft_v, smp, uv - step * f32(i), 0.0)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, clamp(sum / total, vec4f(0.0), vec4f(1.0)));
}
