// First pass of fit: `src` stretched to the frame and box-blurred along x (mode 3 only).
const TAPS: i32 = 64;

fn blur_radius() -> f32 {
    return max(params.blur, 0.0) * globals.size.y;   // in output pixels
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let r = blur_radius();
    if (params.mode != 3 || r < 0.5) { gpufx_write(id, textureSampleLevel(src, smp, uv, 0.0)); return; }
    // Bilinear taps spread evenly over [-r, r]: close to a box blur for a fixed cost;
    // past about 64 px of radius the taps are spaced wider than a pixel.
    var acc = vec4f(0.0);
    for (var i = 0; i < TAPS; i++) {
        let o = (f32(i) + 0.5) / f32(TAPS) * 2.0 - 1.0;
        acc += textureSampleLevel(src, smp, uv + vec2f(o * r / globals.size.x, 0.0), 0.0);
    }
    gpufx_write(id, acc / f32(TAPS));
}
