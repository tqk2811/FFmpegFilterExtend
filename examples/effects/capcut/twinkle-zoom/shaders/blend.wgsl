// Twinkle Zoom, pass 1: dissolve from the first clip to the second over the first 40 % of the transition.

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let keep = 1.0 - clamp(params.progress / 0.4, 0.0, 1.0);
    gpufx_write(id, vec4f(mix(b.rgb, a.rgb, keep), 1.0));
}
