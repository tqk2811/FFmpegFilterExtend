// Fade the first clip down to black over the first half, then up from black into the second.

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    // Darkness rises 0 -> 1 while t goes 0 -> 0.5, then falls 1 -> 0 while t goes 0.5 -> 1.
    let darkness = 1.0 - abs(2.0 * t - 1.0);
    var src: vec4f;
    if (t < 0.5) {
        src = textureSampleLevel(first, smp, uv, 0.0);
    } else {
        src = textureSampleLevel(second, smp, uv, 0.0);
    }
    gpufx_write(id, vec4f(src.rgb * (1.0 - darkness), 1.0));
}
