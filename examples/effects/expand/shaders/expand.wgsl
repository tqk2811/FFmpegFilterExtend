// Signed distance (in uv units) outside the region of half size r around the center:
// negative inside. mode: 0 horizontal band, 1 vertical band, 2 box, 3 circle.
fn outside(uv: vec2f, r: f32) -> f32 {
    let d = abs(uv - 0.5);
    switch params.mode {
        case 0: { return d.x - r * 0.5; }
        case 1: { return d.y - r * 0.5; }
        case 2: { return max(d.x, d.y) - r * 0.5; }
        default: {
            // Circle in pixel-correct units; r = 1 reaches the corners.
            let aspect = vec2f(globals.size.x / globals.size.y, 1.0);
            return length((uv - 0.5) * aspect) - r * length(0.5 * aspect);
        }
    }
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let s = max(params.softness, 1e-4);
    // The second clip fills a region that grows from nothing to full size.
    let m = 1.0 - smoothstep(-s, 0.0, outside(uv, params.progress * (1.0 + 2.0 * s)));
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    gpufx_write(id, mix(a, b, m));
}
