// One plane packed into u32 words for the readback buffer. Each invocation writes one
// word of one row.

@group(0) @binding(2) var<storage, read_write> words: array<u32>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= cv.row_words || id.y >= cv.plane_h) {
        return;
    }
    let per_word = 4u / cv.bytes;
    var word = 0u;
    var last = 0xffffffffu;
    var v = vec4f(0.0);
    for (var k = 0u; k < per_word; k++) {
        let ci = id.x * per_word + k;
        let s = ci / cv.channels;
        if (s >= cv.plane_w) {
            break;
        }
        if (s != last) {
            v = sample(vec2u(s, id.y));
            last = s;
        }
        let ch = channel(ci % cv.channels);
        word |= encode(v[ch], ch) << (k * 8u * cv.bytes);
    }
    words[id.y * cv.row_words + id.x] = word;
}
