// Red Swipe, pass 2: for every marked strip texel, measure its run of marked neighbours and its place in that run when ordered by brightness.
//
// Output (all divided by 255): r = run length before it, g = run length after it,
// b = how many run members sort ahead of it (darker, or equal and earlier).

const STRIP_COLS: u32 = 256u;

fn level(c: vec3f) -> f32 {
    return floor(dot(c, vec3f(0.299, 0.587, 0.114)) * 255.0 + 0.5);
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
    if (own.a < 0.5) {
        gpufx_write(id, vec4f(0.0));
        return;
    }
    let me = level(own.rgb);
    var before = 0;
    var after = 0;
    var ahead = 0;
    for (var k = 1; k < 256; k++) {
        let i = x - k;
        if (i < 0) { break; }
        let o = textureLoad(strip, vec2i(i, y), 0);
        if (o.a < 0.5) { break; }
        before = k;
        if (level(o.rgb) <= me) { ahead += 1; }
    }
    for (var k = 1; k < 256; k++) {
        let i = x + k;
        if (i >= cols) { break; }
        let o = textureLoad(strip, vec2i(i, y), 0);
        if (o.a < 0.5) { break; }
        after = k;
        if (level(o.rgb) < me) { ahead += 1; }
    }
    gpufx_write(id, vec4f(f32(before), f32(after), f32(min(ahead, 255)), 255.0) / 255.0);
}
