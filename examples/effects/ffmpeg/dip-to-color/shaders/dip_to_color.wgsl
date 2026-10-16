@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let p = params.progress;
    let mid = vec4f(params.color.rgb, 1.0);
    if (p < 0.5) {
        gpufx_write(id, mix(a, mid, p * 2.0));
    } else {
        gpufx_write(id, mix(mid, b, p * 2.0 - 1.0));
    }
}
