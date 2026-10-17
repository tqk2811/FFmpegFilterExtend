// Firework Light, pass 5: scale the bokeh result back up to the frame, or keep the sharp picture when no blur runs.

const SPAN: f32 = 2.0;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends of the transition.
    if (params.progress <= 0.0) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    if (params.progress >= 1.0) {
        gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    let t = params.progress * SPAN;
    // The blur only exists between 1/6 s and 11/6 s.
    if (t < 0.16666667 || t >= 1.83333333) {
        gpufx_write(id, textureSampleLevel(lit, smp, uv, 0.0));
        return;
    }
    var strength = 0.0;
    if (t < 1.0) {
        strength = 35.0 * (t - 0.16666667) / 0.83333333 / 79.0;
    } else {
        strength = 35.0 * (1.83333333 - t) / 0.83333333 / 79.0;
    }
    let grid = floor(globals.size * mix(1.0, 0.4, pow(strength, 0.35)));
    // Stay half a texel inside the filled corner so filtering never reads outside it.
    let px = clamp(uv * grid, vec2f(0.5), grid - 0.5);
    gpufx_write(id, textureSampleLevel(bokeh, smp, px / globals.size, 0.0));
}
