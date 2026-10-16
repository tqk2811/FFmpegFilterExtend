// Whip Tear, pass 4: lay the darkened shadow on the second clip, then the torn halves on top.

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let back = textureSampleLevel(second, smp, uv, 0.0).rgb;
    let blur = textureSampleLevel(shadow, smp, uv, 0.0);
    // Strong darkening curve (brightness -1): 1 - (1 - c)^(1/3.5), on the premultiplied blur.
    let dark = clamp(vec3f(1.0) - pow(max(vec3f(1.01) - blur.rgb, vec3f(0.0)), vec3f(1.0 / 3.5)), vec3f(0.0), vec3f(1.0));
    let shaded = dark + back * (1.0 - blur.a);
    let halves = textureSampleLevel(torn, smp, uv, 0.0);
    gpufx_write(id, vec4f(halves.rgb + shaded * (1.0 - halves.a), 1.0));
}
