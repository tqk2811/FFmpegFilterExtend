// Every plane of a YUV frame staying on the GPU in one pass (convert.rs generates the
// plane bindings dst0.. and store_luma/store_chroma). Each invocation writes one chroma
// sample and the luma (and alpha) samples of its block. The workgroup first converts the
// pixels its samples read into workgroup memory once, so the chroma filter does not
// fetch and convert up to 16 pixels per sample. Same values as convert_out_image.wgsl.

const GROUP: u32 = 8u;
// Pixels of a tile per side: GROUP * sub + 4 (the filter reaches 2 pixels out).
var<workgroup> px: array<vec4f, 400>;
var<private> origin: vec2i;
var<private> tile_w: u32;

// Y, U, V and alpha of pixel k (clamped to the frame by fetch), from the tile.
fn at(k: vec2i) -> vec4f {
    let q = vec2u(k - origin);
    return px[q.y * tile_w + q.x];
}

// The stored code (shifted for P010) as the unorm value of the plane texture.
fn plane_value(v: f32, ch: u32) -> f32 {
    return f32(encode(v, ch)) / select(255.0, 65535.0, cv.depth + cv.shift > 8u);
}

@compute @workgroup_size(8, 8)
fn main(
    @builtin(global_invocation_id) id: vec3u,
    @builtin(local_invocation_index) li: u32,
    @builtin(workgroup_id) wg: vec3u,
) {
    let sub = vec2u(cv.sub_x, cv.sub_y);
    origin = vec2i(wg.xy * GROUP * sub) - vec2i(2);
    tile_w = GROUP * cv.sub_x + 4u;
    let n = tile_w * (GROUP * cv.sub_y + 4u);
    for (var t = li; t < n; t += GROUP * GROUP) {
        let c = fetch(origin + vec2i(i32(t % tile_w), i32(t / tile_w)));
        px[t] = vec4f(yuv(c.rgb), c.a);
    }
    workgroupBarrier();
    let s = id.xy;
    for (var dy = 0u; dy < cv.sub_y; dy++) {
        for (var dx = 0u; dx < cv.sub_x; dx++) {
            let p = s * sub + vec2u(dx, dy);
            if (p.x < cv.width && p.y < cv.height) {
                store_luma(vec2i(p), at(vec2i(p)));
            }
        }
    }
    if (s.x >= cv.cwidth || s.y >= cv.cheight) {
        return;
    }
    if (cv.cwidth == cv.width && cv.cheight == cv.height) {
        store_chroma(vec2i(s), at(vec2i(s)));
        return;
    }
    // The triangle filter of sample() in convert_out.wgsl, in the same order and with the
    // same weights, computed once per row and column. Zero weights add nothing (the
    // values are finite), so they are not skipped: no branch in the loop.
    let subf = vec2f(sub);
    let pos = subf * vec2f(s) + 0.5 + vec2f(cv.site_x, cv.site_y) * (subf - 1.0);
    let base = vec2i(floor(pos));
    var wx: array<f32, 4>;
    var wy: array<f32, 4>;
    for (var i = 0; i < 4; i++) {
        let d = abs(vec2f(base + vec2i(i - 2)) + 0.5 - pos) / subf;
        wx[i] = max(1.0 - d.x, 0.0);
        wy[i] = max(1.0 - d.y, 0.0);
    }
    var sum = vec3f(0.0);
    var total = 0.0;
    for (var j = 0; j < 4; j++) {
        for (var i = 0; i < 4; i++) {
            let w = wx[i] * wy[j];
            sum += w * at(base + vec2i(i - 2, j - 2)).xyz;
            total += w;
        }
    }
    store_chroma(vec2i(s), vec4f(sum / total, 1.0));
}
