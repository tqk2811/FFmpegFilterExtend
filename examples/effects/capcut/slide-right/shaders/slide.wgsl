// Push both clips to the right together; the second clip enters from the left edge.

// Quintic ease: slow start, fast middle, slow finish.
fn smooth_quint(x: f32) -> f32 {
    if (x < 0.5) { return 16.0 * pow(x, 5.0); }
    let r = x - 1.0;
    return 1.0 + 16.0 * r * r * r * r * r;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let shift = smooth_quint(clamp(params.progress, 0.0, 1.0));
    // Position in the shifted frame; x < 0 means the strip that has entered from the left.
    let moved = uv - vec2f(shift, 0.0);
    // Wrap into [0, 1), then keep half a texel from each border so the linear sampler
    // never blends the left and right edges together (that blend shows as a seam).
    let half_texel = 0.5 / globals.size;
    let wrapped = clamp(fract(moved), half_texel, 1.0 - half_texel);
    var color = textureSampleLevel(second, smp, wrapped, 0.0).rgb;
    if (moved.x >= 0.0 && moved.x <= 1.0) {
        color = textureSampleLevel(first, smp, wrapped, 0.0).rgb;
    }
    gpufx_write(id, vec4f(color, 1.0));
}
