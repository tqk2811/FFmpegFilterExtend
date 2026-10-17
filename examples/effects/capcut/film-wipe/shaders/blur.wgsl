// Vertical Gaussian motion blur over the film strip, ramping up while it scrolls and fading out as it lands.

// Blur reach at full strength, as a fraction of the picture height, and taps on each side.
const REACH: f32 = 0.1;
const TAPS: i32 = 40;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * 2.0;

    // Strength 0..1: linear rise, hold, linear fall.
    var strength = 0.0;
    if (t < 0.7) { strength = clamp((t - 0.333333) / (0.7 - 0.333333), 0.0, 1.0); }
    else if (t < 1.233333) { strength = 1.0; }
    else { strength = clamp((1.7 - t) / (1.7 - 1.233333), 0.0, 1.0); }

    let centre = textureSampleLevel(strip, smp, uv, 0.0).rgb;
    if (strength <= 0.0) { gpufx_write(id, vec4f(centre, 1.0)); return; }

    let reach = REACH * strength;
    let sigma = reach / 3.0;
    let step = reach / 39.6;
    var sum = centre;
    var weight = 1.0;
    for (var i = 1; i <= TAPS; i++) {
        let d = step * f32(i);
        if (d > reach + 1e-6) { break; }
        let w = exp(-0.5 * d * d / (sigma * sigma));
        // Samples falling off the picture are left out of the average.
        let up = uv.y - d;
        let down = uv.y + d;
        if (up >= 0.0) { sum += textureSampleLevel(strip, smp, vec2f(uv.x, up), 0.0).rgb * w; weight += w; }
        if (down <= 1.0) { sum += textureSampleLevel(strip, smp, vec2f(uv.x, down), 0.0).rgb * w; weight += w; }
    }
    gpufx_write(id, vec4f(sum / weight, 1.0));
}
