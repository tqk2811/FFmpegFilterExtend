@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let dir = vec2f(cos(radians(params.angle)), sin(radians(params.angle)));
    // Position along the wipe direction, 0..1 across the frame.
    let p = dot(uv - 0.5, dir) / (abs(dir.x) + abs(dir.y)) + 0.5;
    let s = params.softness;
    let edge = params.progress * (1.0 + s) - s;
    let m = 1.0 - smoothstep(edge, edge + s, p);
    gpufx_write(id, mix(a, b, m));
}
