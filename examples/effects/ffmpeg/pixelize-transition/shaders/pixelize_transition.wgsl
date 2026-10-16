@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = params.progress;
    // 1 px at both ends, max_size in the middle.
    let size = max(1.0, round(mix(1.0, params.max_size, 1.0 - abs(p * 2.0 - 1.0))));
    let center = (floor(vec2f(id.xy) / size) + 0.5) * size;
    let uv = min(center, globals.size - 0.5) / globals.size;
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    gpufx_write(id, mix(a, b, smoothstep(0.35, 0.65, p)));
}
