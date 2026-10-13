// 16x16 pixels per workgroup (frames already on the GPU). The chroma samples the
// workgroup's pixels read are loaded once into workgroup memory, instead of four
// clamped loads of one or two planes per pixel. The values are the same as load_uv's.

const TILE: u32 = 16u;
// Chroma samples of a tile per side: up to 17 without subsampling, 10 with.
const CTILE: u32 = 18u;

var<workgroup> uv_tile: array<vec2f, 324>;
var<private> uv_origin: vec2i;
var<private> uv_width: u32;

fn uv_at(p: vec2i) -> vec2f {
    let q = vec2u(p - uv_origin);
    return uv_tile[q.y * uv_width + q.x];
}

@compute @workgroup_size(16, 16)
fn main(
    @builtin(global_invocation_id) id: vec3u,
    @builtin(local_invocation_index) li: u32,
    @builtin(workgroup_id) wg: vec3u,
) {
    if (cv.kind != 0u) {
        // chroma_pos is monotonic: the tile's first pixel reads the first sample.
        uv_origin = vec2i(floor(chroma_pos(wg.xy * TILE)));
        uv_width = (TILE - 1u) / cv.sub_x + 3u;
        let n = uv_width * ((TILE - 1u) / cv.sub_y + 3u);
        for (var t = li; t < n; t += TILE * TILE) {
            uv_tile[t] = load_uv(uv_origin + vec2i(i32(t % uv_width), i32(t / uv_width)));
        }
    }
    workgroupBarrier();
    if (id.x >= cv.width || id.y >= cv.height) {
        return;
    }
    textureStore(dst, vec2i(id.xy), pixel(id.xy));
}
