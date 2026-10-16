// Bubble Blur, pass 2: soften the second clip horizontally.

// Tap weights from the centre outwards (not normalised; divided by their sum).
const TAP_WEIGHTS = array<f32, 9>(0.20, 0.19, 0.17, 0.15, 0.13, 0.11, 0.08, 0.05, 0.02);

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    // Blur strength rises to its peak at mid-transition and falls back.
    let strength = 0.48 * (1.0 - abs(2.0 * p - 1.0));
    // Step size is measured on a grid whose short side is 720 px.
    let grid = globals.size * (720.0 / min(globals.size.x, globals.size.y));
    let step = vec2f(1.0, 0.0) * strength * 1.25 / grid;
    var sum = textureSampleLevel(second, smp, uv, 0.0).rgb * TAP_WEIGHTS[0];
    var total = TAP_WEIGHTS[0];
    for (var i = 1; i <= 8; i++) {
        let w = TAP_WEIGHTS[i];
        let o = step * f32(i);
        sum += (textureSampleLevel(second, smp, uv + o, 0.0).rgb + textureSampleLevel(second, smp, uv - o, 0.0).rgb) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
