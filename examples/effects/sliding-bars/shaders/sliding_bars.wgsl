@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let vertical = params.vertical != 0u;
    let n = max(params.count, 1);
    // across: which bar the pixel is in; along: the axis the bar slides on.
    let across = select(uv.y, uv.x, vertical);
    let along = select(uv.x, uv.y, vertical);
    let bar = f32(min(i32(across * f32(n)), n - 1));
    // Each bar slides for `len` of the progress; bar i starts at i * stagger * len, so the
    // last one ends exactly at progress 1 (stagger 1: one after another, 0: all together).
    let stagger = clamp(params.stagger, 0.0, 1.0);
    let len = 1.0 / (1.0 + stagger * f32(n - 1));
    let local = clamp((params.progress - bar * stagger * len) / len, 0.0, 1.0);
    // Where this pixel falls inside the moving bar of the second clip.
    var src = along + (1.0 - local);
    var on_bar = src <= 1.0;
    if (params.direction == 1) {
        src = along - (1.0 - local);
        on_bar = src >= 0.0;
    }
    if (on_bar) {
        let b_uv = select(vec2f(src, uv.y), vec2f(uv.x, src), vertical);
        gpufx_write(id, textureSampleLevel(second, smp, b_uv, 0.0));
    } else {
        gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0));
    }
}
