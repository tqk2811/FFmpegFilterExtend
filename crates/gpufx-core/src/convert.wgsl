// Built-in conversion passes between frame formats and the RGBA effects work in.
// Shared declarations; convert_in.wgsl or convert_out.wgsl follows.

// Layout must match `convert::uniform`.
struct Conv {
    width: u32,           // frame size
    height: u32,
    cwidth: u32,          // chroma plane size
    cheight: u32,
    sub_x: u32,           // chroma subsampling factors, 1 or 2
    sub_y: u32,
    kind: u32,            // 0 RGBA, 1 Y + interleaved UV, 2 Y, U, V planes
    alpha: u32,           // 1: plane 3 holds alpha
    depth: u32,           // bits of a sample value
    shift: u32,           // values are stored << shift (P010)
    full: u32,            // full range YUV
    premul: u32,          // the frame has premultiplied alpha
    kr: f32,              // luma weights of the matrix
    kb: f32,
    site_x: f32,          // chroma position in its block: 0 first sample, 0.5 centre, 1 last
    site_y: f32,
    // Output plane, convert_out only.
    plane_w: u32,         // samples per row
    plane_h: u32,
    channels: u32,        // interleaved channels
    bytes: u32,           // bytes per stored sample, 1 or 2
    row_words: u32,       // u32 words per row in the output buffer
    chroma: u32,          // 1: a subsampled chroma plane
    ch0: u32,             // channel of each interleaved sample: 0 Y/R, 1 U/G, 2 V/B, 3 A
    ch1: u32,
    ch2: u32,
    ch3: u32,
    pad0: u32,
    pad1: u32,
};

@group(0) @binding(0) var<uniform> cv: Conv;

fn code_max() -> f32 {
    return f32((1u << cv.depth) - 1u);
}

// Scale of 8-bit limited range codes for this depth (4 for 10 bits).
fn code_scale() -> f32 {
    return f32(1u << (cv.depth - 8u));
}

fn kg() -> f32 {
    return 1.0 - cv.kr - cv.kb;
}
