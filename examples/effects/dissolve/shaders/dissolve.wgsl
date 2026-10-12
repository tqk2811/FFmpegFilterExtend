// Integer hash (multiply/xorshift mix), the same on every GPU.
fn hash(v: vec3u) -> f32 {
    var x = v.x * 1664525u + v.y * 22695477u + v.z * 2654435761u + 1013904223u;
    x = x ^ (x >> 16u);
    x = x * 2246822519u;
    x = x ^ (x >> 13u);
    x = x * 3266489917u;
    x = x ^ (x >> 16u);
    return f32(x >> 8u) / 16777216.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let cell = vec2u(vec2f(id.xy) / max(params.block, 1.0));
    let r = hash(vec3u(cell, u32(i32(params.seed))));
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    // r < 1 always, so progress = 1 shows only the second clip.
    gpufx_write(id, select(a, b, r < params.progress));
}
