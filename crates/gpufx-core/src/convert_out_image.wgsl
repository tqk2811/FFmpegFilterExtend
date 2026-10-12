// One plane written into a unorm storage texture of a GPU frame (STORAGE_FORMAT is
// replaced by convert.rs). Each invocation writes one sample.

@group(0) @binding(2) var dst: texture_storage_2d<STORAGE_FORMAT, write>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= cv.plane_w || id.y >= cv.plane_h) {
        return;
    }
    let v = sample(id.xy);
    // The stored code (shifted for P010) as the unorm value of the texture.
    let m = select(255.0, 65535.0, cv.bytes == 2u);
    var c = vec4f(0.0, 0.0, 0.0, 1.0);
    for (var k = 0u; k < cv.channels; k++) {
        let ch = channel(k);
        c[k] = f32(encode(v[ch], ch)) / m;
    }
    textureStore(dst, vec2i(id.xy), c);
}
