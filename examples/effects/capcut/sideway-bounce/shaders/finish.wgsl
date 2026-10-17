// Sideway Bounce, pass 4: screen the brightened glow over the shaken picture.

fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        let dx = 3.0 * inv * inv * c.x + 6.0 * inv * s * (c.z - c.x) + 3.0 * s * s * (1.0 - c.z);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Glow gain: up to 3 at the midpoint, back to zero shortly before the end.
fn glow_gain(p: f32) -> f32 {
    let curve = vec4f(0.33333, 0.0, 0.66667, 1.0);
    if (p <= 0.5) { return 3.0 * bezier_ease(clamp(p / 0.5, 0.0, 1.0), curve); }
    return 3.0 * (1.0 - bezier_ease(clamp((p - 0.5) / 0.466667, 0.0, 1.0), curve));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let base = textureSampleLevel(shaken, smp, uv, 0.0).rgb;
    let g = min(textureSampleLevel(glow, smp, uv, 0.0).rgb * glow_gain(params.progress), vec3f(1.0));
    gpufx_write(id, vec4f(1.0 - (1.0 - base) * (1.0 - g), 1.0));
}
