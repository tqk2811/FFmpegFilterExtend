// One invocation per pixel, chroma read straight from the planes (frames uploaded from
// the CPU).

fn uv_at(p: vec2i) -> vec2f {
    return load_uv(p);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= cv.width || id.y >= cv.height) {
        return;
    }
    textureStore(dst, vec2i(id.xy), pixel(id.xy));
}
