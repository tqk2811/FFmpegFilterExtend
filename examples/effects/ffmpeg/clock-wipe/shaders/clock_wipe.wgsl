@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = (uv - params.center) * vec2f(globals.size.x / globals.size.y, 1.0);
    // Angle from 12 o'clock, clockwise, in turns (0..1). atan2(0, 0) is undefined (NaN on
    // Metal and D3D12), so the pivot pixel counts as 12 o'clock.
    let a = select(atan2(p.x, -p.y), 0.0, all(p == vec2f(0.0)));
    var turn = fract(a / 6.28318530718 + 1.0);
    if (params.reverse != 0u) { turn = 1.0 - turn; }
    let s = max(params.softness, 1e-4);
    var m = 1.0 - smoothstep(params.progress * (1.0 + s) - s, params.progress * (1.0 + s), turn);
    // The edges round in f32 for some softness values: keep the end points exact.
    if (params.progress >= 1.0) { m = 1.0; }
    let c0 = textureSampleLevel(first, smp, uv, 0.0);
    let c1 = textureSampleLevel(second, smp, uv, 0.0);
    gpufx_write(id, mix(c0, c1, m));
}
