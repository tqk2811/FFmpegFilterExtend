// Straight linear dissolve from the first clip to the second.

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let weight = clamp(params.progress, 0.0, 1.0);
    let outgoing = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let incoming = textureSampleLevel(second, smp, uv, 0.0).rgb;
    gpufx_write(id, vec4f(mix(outgoing, incoming, weight), 1.0));
}
