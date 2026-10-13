// One plane written into a unorm storage texture of a GPU frame (STORAGE_FORMAT is
// replaced by convert.rs). Each invocation writes one sample.

@group(0) @binding(2) var dst: texture_storage_2d<STORAGE_FORMAT, write>;

// Channel ch of v. Selects rather than v[ch]: a vector indexed by a value known only
// when running can be moved to local memory (twice as slow on NVIDIA).
fn pick(v: vec4f, ch: u32) -> f32 {
    return select(select(select(v.x, v.y, ch == 1u), v.z, ch == 2u), v.w, ch == 3u);
}

// Texture channel k: the stored code (shifted for P010) of plane channel ch as the unorm
// value, or what an unused channel holds (0, alpha 1).
fn code(v: vec4f, k: u32, ch: u32) -> f32 {
    let m = select(255.0, 65535.0, cv.bytes == 2u);
    return select(select(0.0, 1.0, k == 3u), f32(encode(pick(v, ch), ch)) / m, k < cv.channels);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= cv.plane_w || id.y >= cv.plane_h) {
        return;
    }
    let v = sample(id.xy);
    textureStore(dst, vec2i(id.xy), vec4f(code(v, 0u, cv.ch0), code(v, 1u, cv.ch1), code(v, 2u, cv.ch2), code(v, 3u, cv.ch3)));
}
