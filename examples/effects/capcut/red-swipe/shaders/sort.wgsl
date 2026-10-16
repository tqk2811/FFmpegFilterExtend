// Red Swipe, pass 3: each marked strip texel takes the colour of the run member whose brightness order matches its own position, so every run comes out sorted dark to bright.

const STRIP_COLS: u32 = 256u;

fn count(v: f32) -> f32 {
    return round(v * 255.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let cols = i32(min(STRIP_COLS, u32(globals.size.x)));
    let x = i32(id.x);
    let y = i32(id.y);
    if (x >= cols || y >= i32(globals.size.y)) {
        gpufx_write(id, vec4f(0.0));
        return;
    }
    let own = textureLoad(strip, vec2i(x, y), 0);
    let info = textureLoad(ranks, vec2i(x, y), 0);
    let before = count(info.r);
    let after = count(info.g);
    // The slot this texel fills is its position in the run.
    let slot = before;
    if (own.a < 0.5 || abs(count(info.b) - slot) < 1.0) {
        gpufx_write(id, own);
        return;
    }
    var shift = 0;
    var best = 1024.0;
    var found = false;
    for (var k = 1; k < 256; k++) {
        if (x - k < 0 || f32(k) > before) { break; }
        let gap = abs(count(textureLoad(ranks, vec2i(x - k, y), 0).b) - slot);
        if (gap < 1.0) { shift = -k; found = true; break; }
        if (gap < best) { best = gap; shift = -k; }
    }
    if (!found) {
        for (var k = 1; k < 256; k++) {
            if (x + k >= cols || f32(k) > after) { break; }
            let gap = abs(count(textureLoad(ranks, vec2i(x + k, y), 0).b) - slot);
            if (gap < 1.0) { shift = k; break; }
            if (gap < best) { best = gap; shift = k; }
        }
    }
    let picked = textureLoad(strip, vec2i(x + shift, y), 0);
    gpufx_write(id, vec4f(picked.rgb, own.a));
}
