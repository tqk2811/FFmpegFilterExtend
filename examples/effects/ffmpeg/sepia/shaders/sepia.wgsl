@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let s = vec3f(
        dot(c.rgb, vec3f(0.393, 0.769, 0.189)),
        dot(c.rgb, vec3f(0.349, 0.686, 0.168)),
        dot(c.rgb, vec3f(0.272, 0.534, 0.131)),
    );
    gpufx_write(id, vec4f(mix(c.rgb, s, params.amount), c.a));
}
