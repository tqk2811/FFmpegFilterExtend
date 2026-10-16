@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    var uv = gpufx_uv(id);
    if (params.mode == 0 || params.mode == 2) { uv.x = 1.0 - uv.x; }
    if (params.mode == 1 || params.mode == 2) { uv.y = 1.0 - uv.y; }
    gpufx_write(id, textureSampleLevel(src, smp, uv, 0.0));
}
