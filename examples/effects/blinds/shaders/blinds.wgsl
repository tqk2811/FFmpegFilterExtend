@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let coord = select(uv.y, uv.x, params.vertical != 0u);
    let f = fract(coord * f32(max(params.count, 1)));
    let s = max(params.softness, 1e-4);
    let m = 1.0 - smoothstep(params.progress * (1.0 + s) - s, params.progress * (1.0 + s), f);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    gpufx_write(id, mix(a, b, m));
}
