// The first clip zooms in and is dragged upwards with the second clip stacked below it, bulging vertically while it moves, under a faint camera viewfinder mark.

// Animation time covered by progress 0..1, in seconds.
const SPAN: f32 = 2.0;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bez(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let mid = 0.5 * (lo + hi);
        if (bez(c.x, c.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return bez(c.y, c.w, 0.5 * (lo + hi));
}

// One keyframe span: `before` until t0, eases a -> b inside, b afterwards.
fn span(before: f32, t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return before; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

const SNAP = vec4f(0.9, 0.0, 0.1, 1.0);
const SOFT = vec4f(0.75, 0.0, 0.25, 1.0);

// Vertical centre of the first clip, in frame heights from the top.
fn stack_y(t: f32) -> f32 {
    var y = span(540.0, t, 0.233333, 0.566667, 540.0, 553.0, SNAP);
    y = span(y, t, 0.566667, 1.166667, 553.0, -808.0, vec4f(0.6, 0.0, 0.1, 1.0));
    y = span(y, t, 1.166667, 1.5, -808.0, -540.0, SNAP);
    return y / 1080.0;
}

fn stack_zoom(t: f32) -> f32 {
    var s = span(1.0, t, 0.233333, 0.566667, 1.0, 1.264, SNAP);
    return span(s, t, 1.166667, 1.5, 1.264, 1.0, SNAP);
}

fn bulge_amount(t: f32) -> f32 {
    if (t < 0.233333 || t > 1.5) { return 0.0; }
    var b = span(0.0, t, 0.233333, 0.566667, 0.0, 25.0, SOFT);
    b = span(b, t, 0.566667, 0.8, 25.0, 40.0, vec4f(0.75, 0.0, 0.8333333, 0.8333333));
    b = span(b, t, 0.8, 1.166667, 40.0, 25.0, vec4f(0.1666667, 0.1666667, 0.25, 1.0));
    b = span(b, t, 1.166667, 1.5, 25.0, 0.0, SOFT);
    return b / 100.0;
}

// Clips stacked vertically: first on top, second right below, both scaled about their own centres.
fn stack(uv: vec2f, t: f32) -> vec3f {
    let s = stack_zoom(t);
    let cy = stack_y(t);
    let a = (uv - vec2f(0.5, cy)) / s + 0.5;
    if (all(a >= vec2f(0.0)) && all(a <= vec2f(1.0))) {
        return textureSampleLevel(first, smp, a, 0.0).rgb;
    }
    let b = (uv - vec2f(0.5, cy + s)) / s + 0.5;
    if (all(b >= vec2f(0.0)) && all(b <= vec2f(1.0))) {
        return textureSampleLevel(second, smp, b, 0.0).rgb;
    }
    return vec3f(0.0);
}

// Horizontal bulge: columns follow a circular arc and the picture swells vertically towards the middle.
fn bulge(uv: vec2f, b: f32) -> vec2f {
    if (b <= 1e-4) { return uv; }
    let k = 1.0 / clamp(b, 1e-4, 1.0) - 1.0;
    let r = sqrt(1.0 + k * k);
    let half_arc = atan2(1.0, k);
    let start = atan2(k, 1.0);
    let x = uv.x * 2.0 - 1.0;
    let sx = (acos(clamp(-x / r, -1.0, 1.0)) - start) / (2.0 * half_arc);
    let lift = sqrt(max(r * r - x * x, 0.0)) - k;
    return vec2f(sx, 0.5 + (uv.y - 0.5) / (1.0 + lift));
}

// Viewfinder mark drawn on a 413-unit square: four corner brackets and a centre cross.
fn box_cover(q: vec2f, lo: vec2f, hi: vec2f, px: f32) -> f32 {
    let d = min(q - lo, hi - q);
    let c = clamp(d / px + 0.5, vec2f(0.0), vec2f(1.0));
    return c.x * c.y;
}

fn viewfinder(q: vec2f, px: f32) -> f32 {
    let w = 3.6;
    var a = 0.027;
    let l = 41.4;
    let r = 384.6;
    let tp = 26.4;
    let bt = 368.2;
    a = max(a, box_cover(q, vec2f(l, tp), vec2f(163.5, tp + w), px));
    a = max(a, box_cover(q, vec2f(261.0, tp), vec2f(r, tp + w), px));
    a = max(a, box_cover(q, vec2f(l, bt - w), vec2f(163.5, bt), px));
    a = max(a, box_cover(q, vec2f(261.0, bt - w), vec2f(r, bt), px));
    a = max(a, box_cover(q, vec2f(l, tp), vec2f(l + w, 148.5), px));
    a = max(a, box_cover(q, vec2f(l, 246.0), vec2f(l + w, bt), px));
    a = max(a, box_cover(q, vec2f(r - w, tp), vec2f(r, 148.5), px));
    a = max(a, box_cover(q, vec2f(r - w, 246.0), vec2f(r, bt), px));
    a = max(a, box_cover(q, vec2f(156.0, 193.6), vec2f(269.0, 199.0), px));
    a = max(a, box_cover(q, vec2f(209.6, 141.0), vec2f(214.6, 254.0), px));
    if (any(q < vec2f(0.0)) || any(q > vec2f(413.0))) { return 0.0; }
    return a;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    // Exact clips at the ends of the transition.
    if (p <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (p >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = p * SPAN;

    var col = stack(bulge(uv, bulge_amount(t)), t);

    var mark_size = span(0.25, t, 0.233333, 0.566667, 0.25, 0.16, SNAP);
    mark_size = span(mark_size, t, 0.633333, 0.966667, 0.16, 0.25, SNAP);
    var mark_alpha = span(0.0, t, 0.166667, 0.5, 0.0, 0.75, SNAP);
    mark_alpha = span(mark_alpha, t, 0.7, 1.033333, 0.75, 0.0, SNAP);
    if (mark_alpha > 0.0) {
        let dims = vec2f(textureDimensions(first));
        let side = mark_size * max(dims.x, dims.y);
        let centre = vec2f(0.498125, 0.493333) * dims;
        let q = ((uv * dims - centre) / side + 0.5) * 413.0;
        let a = viewfinder(q, 413.0 / side) * mark_alpha;
        col = mix(col, vec3f(1.0), a);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
