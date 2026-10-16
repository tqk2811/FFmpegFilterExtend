// Three diagonal strips swap from the first clip to the second one after another, each punching in, blurring along the diagonal and settling, while the frame shakes.

// Strip boundaries sit on lines u - v = +-EDGE.
const EDGE: f32 = 0.45;

// Cubic ease through (0,0), (x1,y1), (x2,y2), (1,1): solve x for the curve parameter, return y.
fn ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let s = 0.5 * (lo + hi);
        let r = 1.0 - s;
        let bx = 3.0 * r * r * s * c.x + 3.0 * r * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * c.y + 3.0 * r * s * s * c.w + s * s * s;
}

// Value from a to b between times t0 and t1, shaped by the curve c.
fn key(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t <= t0) { return a; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

// Streak strength: ramps 0 -> 50 over 2 frames, holds, ramps back.
fn streak(t: f32, start: f32, stop: f32) -> f32 {
    let ramp = 0.066667;
    if (t <= start || t >= stop + ramp) { return 0.0; }
    if (t < start + ramp) { return 50.0 * (t - start) / ramp; }
    if (t < stop) { return 50.0; }
    return 50.0 * (1.0 - (t - stop) / ramp);
}

// Zoom by percent s around the top-left (corner = 0) or bottom-right (corner = 1) corner.
fn zoomed(q: vec2f, s: f32, corner: f32) -> vec2f {
    let pivot = vec2f(corner);
    return pivot + (q - pivot) * (100.0 / s);
}

struct Strip {
    swap: f32,
    out_start: f32, out_end: f32, out_corner: f32, out_curve: vec4f,
    in_start: f32, in_end: f32, in_corner: f32, in_curve: vec4f,
}

fn strip_info(i: i32) -> Strip {
    if (i == 0) {
        return Strip(0.166667, 0.0, 0.2, 0.0, vec4f(0.166667, 0.1, 0.0, 1.0),
                     0.133333, 0.333333, 1.0, vec4f(0.166667, 0.2, 0.0, 1.0));
    }
    if (i == 1) {
        return Strip(0.333333, 0.166667, 0.4, 1.0, vec4f(0.166667, 0.116667, 0.0, 1.0),
                     0.266667, 0.5, 0.0, vec4f(0.166667, 0.116667, 0.0, 1.0));
    }
    return Strip(0.5, 0.333333, 0.566667, 0.0, vec4f(0.166667, 0.116667, 0.0, 1.0),
                 0.433333, 0.666667, 1.0, vec4f(0.166667, 0.233333, 0.0, 1.0));
}

// Picture of strip i (already zoomed) at q; q outside the frame gives nothing.
fn strip_picture(q: vec2f, t: f32, i: i32) -> vec3f {
    let s = strip_info(i);
    if (t <= s.swap) {
        let z = key(t, s.out_start, s.out_end, 100.0, 200.0, s.out_curve);
        return textureSampleLevel(first, smp, zoomed(q, z, s.out_corner), 0.0).rgb;
    }
    let z = key(t, s.in_start, s.in_end, 200.0, 100.0, s.in_curve);
    return textureSampleLevel(second, smp, zoomed(q, z, s.in_corner), 0.0).rgb;
}

fn inside(q: vec2f) -> bool {
    return q.x >= 0.0 && q.y >= 0.0 && q.x <= 1.0 && q.y <= 1.0;
}

// Tap layout of the directional blur for a given strength: x = taps per side, y = sigma, zw = step.
fn blur_layout(amount: f32, aspect: vec2f) -> vec4f {
    var scale = 0.8; var bias = 0.0; var k = 1.0;
    if (amount > 10.0) { scale = 0.7; bias = 2.0; k = 0.78; }
    var count = (scale * amount + bias) * k;
    if (count < 2.0) { count = floor(count + 0.5); }
    // Low quality setting (0.1): the tap count is cut to 10^-0.8 of the nominal one.
    let taps = count * pow(10.0, -0.8);
    let reach = amount / 1000.0;
    let stride = reach / max(taps, 1e-5);
    let dir = vec2f(0.70710678, 0.70710678) * aspect * stride;
    return vec4f(taps, reach / 3.0, dir);
}

fn weight(d: vec2f, sigma: f32) -> f32 {
    let l = length(d);
    return exp(-0.5 * l * l / (sigma * sigma));
}

// One directional blur of strip i.
fn strip_blurred(q: vec2f, t: f32, i: i32, lay: vec4f) -> vec3f {
    if (lay.x < 1e-5) { return strip_picture(q, t, i); }
    var sum = strip_picture(q, t, i);
    var total = 1.0;
    for (var k = 1; k <= 64; k++) {
        if (f32(k) > lay.x) { break; }
        let d = lay.zw * f32(k);
        let w = weight(d, lay.y);
        if (inside(q - d)) { sum += strip_picture(q - d, t, i) * w; total += w; }
        if (inside(q + d)) { sum += strip_picture(q + d, t, i) * w; total += w; }
    }
    return sum / total;
}

// Streak blurs stack: each one smears everything already drawn below it. Several stacked
// passes are folded into one wider blur (taps add up, variances add up).
fn stacked(a: vec4f, b: vec4f) -> vec4f {
    if (a.x < 1e-5) { return b; }
    if (b.x < 1e-5) { return a; }
    let stride = select(b.zw, a.zw, length(a.zw) > length(b.zw));
    let reach = a.x * length(a.zw) + b.x * length(b.zw);
    return vec4f(min(reach / max(length(stride), 1e-6), 48.0), sqrt(a.y * a.y + b.y * b.y), stride);
}

fn scene(q: vec2f, t: f32, aspect: vec2f) -> vec3f {
    let side = q.x - q.y;
    let early = blur_layout(streak(t, 0.0, 0.3), aspect);
    let late = blur_layout(streak(t, 0.166667, 0.466667), aspect);
    // Middle and last streak passes run on the same schedule.
    let late_twice = stacked(late, late);
    if (side < -EDGE) {
        return strip_blurred(q, t, 0, stacked(early, late_twice));
    }
    if (side <= EDGE) {
        return strip_blurred(q, t, 1, late_twice);
    }
    return strip_blurred(q, t, 2, late);
}

// Shake wobble components, in pixels of a 1080-pixel short side.
fn wobble(t: f32) -> vec2f {
    let x = 3.14159265 * t * 4.0;
    let dx = 0.25 * cos(x) + 0.16 * sin(1.5 * x) + 0.09 * cos(2.5 * x);
    let dy = 0.25 * sin(x) + 0.16 * cos(1.5 * x) + 0.09 * sin(2.5 * x);
    return vec2f(dx, dy) * 192.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0);

    let size = vec2f(textureDimensions(first));
    let base = max(min(size.x, size.y), max(size.x, size.y) * 0.5);
    let aspect = vec2f(base / size.x, base / size.y);

    // Shake: amplitude swells then dies, while the frame zooms in to 1/0.9 and back.
    var amp = key(t, 0.166667, 0.533333, 0.0, 0.5, vec4f(0.166667, 0.0, 0.38, 1.0));
    var zoom = key(t, 0.166667, 0.533333, 1.0, 0.9, vec4f(0.166667, 0.366667, 0.38, 1.0));
    if (t >= 0.533333) {
        amp = key(t, 0.533333, 0.933333, 0.5, 0.0, vec4f(0.166667, 0.2, 0.38, 1.0));
        zoom = key(t, 0.533333, 0.933333, 0.9, 1.0, vec4f(0.166667, 0.4, 0.38, 1.0));
    }
    let px = size * (1080.0 / min(size.x, size.y));
    // With `animate` off the wobble clock stays at 0, as in CapCut's export.
    let clock = select(0.0, t * params.duration, params.animate != 0u);
    let shift = wobble(clock) * amp * vec2f(1.0, -1.0) / px;
    var q = vec2f(0.5) + (uv - vec2f(0.5)) * zoom + shift * zoom;
    // Horizontal wrap-around, vertical mirror.
    q.x = fract(q.x);
    q.y = abs((q.y + 1.0) - 2.0 * floor((q.y + 1.0) * 0.5) - 1.0);

    gpufx_write(id, vec4f(scene(q, t, aspect), 1.0));
}
