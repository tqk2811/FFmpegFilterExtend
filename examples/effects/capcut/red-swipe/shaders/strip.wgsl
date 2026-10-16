// Red Swipe, pass 1: the vertical streaks are worked out on a strip of STRIP_COLS columns; lay the picture out there turned on its side and mark the pixels bright enough to be sorted.
//
// Texel (i, j) of the strip, i < STRIP_COLS and j < height, holds the picture at
// x = (j + 0.5) / height, y = (i + 0.5) / STRIP_COLS, so each strip row is one picture
// column sampled top to bottom. Alpha is 1 where the pixel takes part in the sort.

const STRIP_COLS: u32 = 256u;
// Scene clock: `progress` maps onto [CLOCK_START, CLOCK_END] seconds.
const CLOCK_START: f32 = 0.46713380046713;
const CLOCK_END: f32 = 1.46812480146814;
// Scene time at which the second clip covers the first.
const SWAP: f32 = 0.93426760093427;

fn ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let s = 0.5 * (lo + hi);
        let r = 1.0 - s;
        let bx = 3.0 * r * r * s * c.x + 3.0 * r * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * c.y + 3.0 * r * s * s * c.w + s * s * s;
}

fn key(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return a; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

// Brightness a pixel needs to join the sort: falls to 0 at the swap, then rises back.
fn cutoff(t: f32) -> f32 {
    if (t < SWAP) {
        return key(t, 0.533867, SWAP, 1.0, 0.0, vec4f(0.33333333, 0.0, 0.66666667, 1.0));
    }
    return key(t, SWAP, 1.368035, 0.0, 1.0, vec4f(0.166666667, 0.0, 0.833333333, 1.0));
}

fn to_byte(v: vec3f) -> vec3f {
    return floor(clamp(v, vec3f(0.0), vec3f(1.0)) * 255.0 + 0.5) / 255.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let cols = min(STRIP_COLS, u32(globals.size.x));
    let rows = u32(globals.size.y);
    if (id.x >= cols || id.y >= rows) {
        gpufx_write(id, vec4f(0.0));
        return;
    }
    let t = mix(CLOCK_START, CLOCK_END, params.progress);
    let p = vec2f((f32(id.y) + 0.5) / f32(rows), (f32(id.x) + 0.5) / f32(cols));
    var c: vec3f;
    if (t >= SWAP) {
        c = textureSampleLevel(second, smp, p, 0.0).rgb;
    } else {
        c = textureSampleLevel(first, smp, p, 0.0).rgb;
    }
    c = to_byte(c);
    let luma = dot(c, vec3f(0.299, 0.587, 0.114));
    let marked = select(0.0, 1.0, luma >= cutoff(t));
    gpufx_write(id, vec4f(c, marked));
}
