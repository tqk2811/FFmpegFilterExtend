@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let b = max(params.block, 1.0);
    let cell = (floor((vec2f(id.xy) + 0.5) / b) + 0.5) * b;
    gpufx_write(id, textureSampleLevel(src, smp, cell / globals.size, 0.0));
}
