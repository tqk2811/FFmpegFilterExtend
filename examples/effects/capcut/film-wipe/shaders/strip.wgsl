// Draws the clip framed in a black film strip (rounded window, sprocket holes) that shrinks, scrolls down and grows back.
//
// Layout in a 720 x 720 scene (stretched over the picture); time runs 0..2 s over `progress`.
// The film frame is described on a 360 x 360 grid and covers the 720 scene layer.

const SCENE: f32 = 720.0;
// Vertical offsets of the four strip frames, relative to the moving strip.
const FRAME_OFFSETS: array<f32, 4> = array<f32, 4>(0.0, 727.0, -720.0, -1443.0);
// Time the clip shown in the frames switches from the first to the second.
const SWAP_TIME: f32 = 1.033333;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let m = 0.5 * (lo + hi);
        let inv = 1.0 - m;
        let bx = 3.0 * inv * inv * m * c.x + 3.0 * inv * m * m * c.z + m * m * m;
        if (bx > x) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Value animated from `a` to `b` between times t0 and t1, held outside.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, curve: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, curve));
}

// Straight-line motion between two values.
fn ramp(t: f32, t0: f32, t1: f32, a: f32, b: f32) -> f32 {
    return mix(a, b, clamp((t - t0) / (t1 - t0), 0.0, 1.0));
}

// Vertical centre of the strip: drifts down, then loops through the frames twice before settling.
fn strip_y(t: f32) -> f32 {
    if (t < 0.7) { return keyed(t, 0.333333, 0.7, 360.0, 1090.0, vec4f(0.333333, 0.0, 0.833333, 0.833333)); }
    if (t < 0.733333) { return ramp(t, 0.7, 0.733333, 1090.0, -366.0); }
    if (t < 1.233333) { return ramp(t, 0.733333, 1.233333, -366.0, 1809.0); }
    if (t < 1.266667) { return ramp(t, 1.233333, 1.266667, 1809.0, -366.0); }
    return keyed(t, 1.266667, 1.633333, -366.0, 1080.0, vec4f(0.166667, 0.166667, 0.666667, 1.0));
}

// Signed distance to a rounded box (negative inside).
fn rounded_box(p: vec2f, centre: vec2f, half: vec2f, r: f32) -> f32 {
    let q = abs(p - centre) - half + vec2f(r);
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Opacity of the black film at grid point g (0..360), with `aa` grid units of edge softness.
fn film_cover(g: vec2f, aa: f32) -> f32 {
    // Outer edge of the strip.
    let body = rounded_box(g, vec2f(180.0, 180.0), vec2f(178.5, 154.0), 3.0);
    // The picture window.
    var hole = rounded_box(g, vec2f(180.0, 181.0), vec2f(129.0, 135.0), 16.0);
    // Sprocket holes on both edges, every 25 grid units.
    let row = clamp(round((g.y - 44.5) / 25.0), 0.0, 11.0);
    let hy = 44.5 + row * 25.0;
    hole = min(hole, rounded_box(g, vec2f(22.0, hy), vec2f(7.0, 5.5), 2.5));
    hole = min(hole, rounded_box(g, vec2f(334.0, hy), vec2f(7.0, 5.5), 2.5));
    let d = max(body, -hole);
    return clamp(0.5 - d / aa, 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * 2.0;
    let p = uv * SCENE;

    // Scale of the clip layer and of the film frame laid over it.
    let on_first = t < SWAP_TIME;
    var clip_scale: f32;
    var frame_scale: f32;
    if (on_first) {
        clip_scale = keyed(t, 0.266667, 0.833333, 1.0, 0.7, vec4f(0.166667, 0.314815, 0.0, 1.0));
        frame_scale = keyed(t, 0.266667, 0.433333, 1.4875, 1.2375, vec4f(0.166667, 0.104167, 0.0, 1.0));
    } else {
        clip_scale = keyed(t, 1.233333, 1.766667, 0.7, 1.0, vec4f(1.0, 0.0, 0.833333, 0.703704));
        frame_scale = keyed(t, 1.6, 1.766667, 1.2375, 1.4875, vec4f(1.0, 0.0, 0.833333, 0.861111));
    }
    let film_scale = clip_scale * frame_scale;
    // Edge softness: one output pixel measured on the film grid.
    let aa = SCENE / (globals.size.y * film_scale * 2.0);

    let y0 = strip_y(t) - 360.0;
    var col = vec3f(0.0);
    // The frame nearest to this pixel is drawn last, on top of its neighbours' film edges.
    var nearest = 0;
    for (var i = 1; i < 4; i++) {
        if (abs(p.y - 360.0 - y0 - FRAME_OFFSETS[i]) < abs(p.y - 360.0 - y0 - FRAME_OFFSETS[nearest])) { nearest = i; }
    }
    for (var n = 0; n < 5; n++) {
        if (n == nearest) { continue; }
        let i = select(n, nearest, n == 4);
        let local = p - vec2f(360.0, 360.0 + y0 + FRAME_OFFSETS[i]);
        // The clip, scaled about the frame centre.
        let q = local / (SCENE * clip_scale) + 0.5;
        var layer = vec4f(0.0);
        if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
            var c: vec3f;
            if (on_first) { c = textureSampleLevel(first, smp, q, 0.0).rgb; }
            else { c = textureSampleLevel(second, smp, q, 0.0).rgb; }
            layer = vec4f(c, 1.0);
        }
        // Black film over it.
        let g = local / (film_scale * 2.0) + 180.0;
        if (all(g >= vec2f(0.0)) && all(g <= vec2f(360.0))) {
            let cover = film_cover(g, aa);
            layer = vec4f(layer.rgb * (1.0 - cover), max(layer.a, cover));
        }
        col = col * (1.0 - layer.a) + layer.rgb;
    }
    gpufx_write(id, vec4f(col, 1.0));
}
