@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    var dir = vec2f(-1.0, 0.0);
    if (params.direction == 1) { dir = vec2f(1.0, 0.0); }
    if (params.direction == 2) { dir = vec2f(0.0, -1.0); }
    if (params.direction == 3) { dir = vec2f(0.0, 1.0); }
    let t = smoothstep(0.0, 1.0, params.progress);
    // The first clip moves along dir; the second follows one frame behind.
    let a_uv = uv - dir * t;
    let b_uv = a_uv + dir;
    if (all(a_uv >= vec2f(0.0)) && all(a_uv <= vec2f(1.0))) {
        gpufx_write(id, textureSampleLevel(first, smp, a_uv, 0.0));
    } else {
        gpufx_write(id, textureSampleLevel(second, smp, b_uv, 0.0));
    }
}
