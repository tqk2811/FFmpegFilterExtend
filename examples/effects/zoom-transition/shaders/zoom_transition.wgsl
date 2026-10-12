@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    let scale = mix(1.0, params.zoom, smoothstep(0.0, 1.0, p));
    let zuv = params.center + (uv - params.center) / scale;
    let a = textureSampleLevel(first, smp, zuv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    gpufx_write(id, mix(a, b, smoothstep(0.4, 1.0, p)));
}
