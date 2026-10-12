@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    // Same size as the output: read the texel directly, exact on every GPU.
    let c = textureLoad(src, vec2i(id.xy), 0);
    gpufx_write(id, vec4f(mix(c.rgb, 1.0 - c.rgb, params.amount), c.a));
}
