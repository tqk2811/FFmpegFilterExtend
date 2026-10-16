@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let cell = max(params.cell, 1.0);
    // Distance from the centre of the cell, in cells (0 .. 0.5).
    let q = abs(fract((vec2f(id.xy) + 0.5) / cell) - 0.5);
    let half_side = 0.5 * params.progress;
    let incoming = (q.x < half_side && q.y < half_side) || params.progress >= 1.0;
    let c = select(textureSampleLevel(first, smp, uv, 0.0), textureSampleLevel(second, smp, uv, 0.0), incoming);
    gpufx_write(id, c);
}
