@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = (uv - params.center) * vec2f(globals.size.x / globals.size.y, 1.0);
    // Angle from 12 o'clock, clockwise, in turns (0..1).
    var turn = fract(atan2(p.x, -p.y) / 6.28318530718 + 1.0);
    if (params.reverse != 0u) { turn = 1.0 - turn; }
    let s = max(params.softness, 1e-4);
    let m = 1.0 - smoothstep(params.progress * (1.0 + s) - s, params.progress * (1.0 + s), turn);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    gpufx_write(id, mix(a, b, m));
}
