@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let y = dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722));
    gpufx_write(id, vec4f(mix(c.rgb, vec3f(y), params.amount), c.a));
}
