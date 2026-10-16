// Screen modes of slideshow tools. The output has the size of `canvas`; `src` is fitted in.
// Mode 3 draws `src` centred over a copy of it stretched to the frame and box-blurred,
// in two passes: blur_h.wgsl blurs that copy along x, this pass along y and composes.
const TAPS: i32 = 64;

fn blur_radius() -> f32 {
    return max(params.blur, 0.0) * globals.size.y;   // in output pixels
}

fn over(top: vec4f, bottom: vec4f) -> vec4f {
    let a = top.a + bottom.a * (1.0 - top.a);
    let rgb = select(vec3f(0.0), (top.rgb * top.a + bottom.rgb * bottom.a * (1.0 - top.a)) / a, a > 0.0);
    return vec4f(rgb, a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let out_px = globals.size;
    let src_px = vec2f(textureDimensions(src));
    // Behind the picture: `color` over the canvas, or in mode 3 the blurred copy.
    var bg = over(params.color, textureSampleLevel(canvas, smp, uv, 0.0));
    if (params.mode == 2) { gpufx_write(id, over(textureSampleLevel(src, smp, uv, 0.0), bg)); return; }
    if (params.mode == 1) {
        // Cover: scale to fill, crop the overflow evenly.
        let s = max(out_px.x / src_px.x, out_px.y / src_px.y);
        let q = (uv - 0.5) * out_px / (src_px * s) + 0.5;
        gpufx_write(id, over(textureSampleLevel(src, smp, q, 0.0), bg));
        return;
    }
    // Contain, never enlarged unless asked.
    var s = min(out_px.x / src_px.x, out_px.y / src_px.y);
    if (params.upscale == 0u) { s = min(s, 1.0); }
    let q = (uv - 0.5) * out_px / (src_px * s) + 0.5;
    if (params.mode == 3) {
        let r = blur_radius();
        if (r < 0.5) {
            bg = textureSampleLevel(blurred_h, smp, uv, 0.0);
        } else {
            var acc = vec4f(0.0);
            for (var i = 0; i < TAPS; i++) {
                let o = (f32(i) + 0.5) / f32(TAPS) * 2.0 - 1.0;
                acc += textureSampleLevel(blurred_h, smp, uv + vec2f(0.0, o * r / out_px.y), 0.0);
            }
            bg = acc / f32(TAPS);
        }
    }
    if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
        gpufx_write(id, over(textureSampleLevel(src, smp, q, 0.0), bg));
    } else {
        gpufx_write(id, bg);
    }
}
