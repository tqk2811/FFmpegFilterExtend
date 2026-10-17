// Hard cut hidden under a burst of warm, high-contrast light leak: a slowly evolving gradient-noise field tinted from dark red through orange to yellow, screened over the picture.

// Animation clock: progress 0..1 covers this window of seconds.
const CLOCK_START: f32 = 0.3333333;
const CLOCK_SPAN: f32 = 1.3333333;

fn bez(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let mid = 0.5 * (lo + hi);
        if (bez(c.x, c.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return bez(c.y, c.w, 0.5 * (lo + hi));
}

fn span(before: f32, t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return before; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

// Phase of the noise field (in degrees, as the animation keys it).
fn phase_deg(t: f32) -> f32 {
    var e = span(189.0, t, 0.766667, 1.0, 189.0, 405.235413, vec4f(0.443411806, 0.0, 0.558115645, -0.697710707));
    return span(e, t, 1.0, 1.233333, 405.235413, 720.0, vec4f(0.222485792, 0.587216564, 0.527913631, 1.0));
}

fn leak_strength(t: f32) -> f32 {
    var o = span(0.0, t, 0.7, 0.766667, 0.0, 1.0, LINEAR);
    return span(o, t, 1.233333, 1.3, 1.0, 0.0, LINEAR);
}

// Rotation about (0.5, 0.5) in an aspect-corrected frame.
fn turn(p_in: vec2f, angle: f32, aspect: f32) -> vec2f {
    var p = p_in;
    p.y /= aspect;
    let s = sin(angle);
    let c = cos(angle);
    p -= vec2f(0.5);
    p = vec2f(c * p.x - s * p.y, s * p.x + c * p.y);
    p += vec2f(0.5);
    p.y *= aspect;
    return p;
}

fn cell_hash(p: vec2f) -> f32 {
    let f = fract(p * 1324.5179);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

const LOOP_LEN: f32 = 300.0;

// Pseudo-random gradient for a lattice cell, cross-faded between two integer phase steps.
fn cell_gradient(cell: vec2f, phase: f32) -> vec2f {
    let jitter = cell_hash(cell);
    let ph = phase + jitter;
    let k0 = floor(ph - LOOP_LEN * floor(ph / LOOP_LEN));
    let ph1 = ph + 1.0;
    let k1 = floor(ph1 - LOOP_LEN * floor(ph1 / LOOP_LEN));
    let a = fract(cell * (34.532 + k0 * 4.412 + 0.3973));
    let a2 = a + vec2f(dot(a, a.yx + vec2f(15.434)));
    let b = fract(cell * (34.532 + k1 * 4.412 + 0.3973));
    let b2 = b + vec2f(dot(b, b.yx + vec2f(15.434)));
    let ga = fract((a2 + a2.yx + vec2f(0.523)) * a2.yx + vec2f(jitter));
    let gb = fract((b2 + b2.yx + vec2f(0.523)) * b2.yx + vec2f(jitter));
    return mix(ga, gb, vec2f(fract(ph))) * 2.0 - 1.0;
}

fn gradient_noise(p: vec2f, phase: f32, dims: vec2f) -> f32 {
    let grid = vec2f(720.0) * dims / min(dims.x, dims.y);
    let q = p * grid / 100.0;
    let i = floor(q);
    let f = fract(q);
    let w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let n00 = dot(cell_gradient(i, phase), f);
    let n10 = dot(cell_gradient(i + vec2f(1.0, 0.0), phase), f - vec2f(1.0, 0.0));
    let n01 = dot(cell_gradient(i + vec2f(0.0, 1.0), phase), f - vec2f(0.0, 1.0));
    let n11 = dot(cell_gradient(i + vec2f(1.0, 1.0), phase), f - vec2f(1.0, 1.0));
    return mix(mix(n00, n10, w.x), mix(n01, n11, w.x), w.y) * 0.5 + 0.5;
}

const SHADOW = vec3f(0.27428, 0.0356127, 0.0356127);
const MIDTONE = vec3f(1.0, 0.5128074, 0.1961397);
const HIGHLIGHT = vec3f(1.0, 0.9768382, 0.0);

fn leak_colour(uv: vec2f, t: f32, dims: vec2f) -> vec3f {
    let aspect = dims.x / dims.y;
    // Bottom-up texture coordinates, offset one frame width and spread 10x.
    let v = vec2f(uv.x, 1.0 - uv.y);
    let p = turn((v - vec2f(1.0, 0.0)) / 10.0, -92.0 * 0.017453292, aspect) - vec2f(10.0);
    var n = clamp(gradient_noise(p, phase_deg(t) / 120.0, dims), 0.0, 1.0) - 0.03;
    n = clamp((n - 0.5) * 11.0 + 0.5, 0.0, 1.0);
    var tint: vec3f;
    if (n < 0.5) { tint = mix(SHADOW, MIDTONE, n / 0.5); } else { tint = mix(MIDTONE, HIGHLIGHT, (n - 0.5) / 0.5); }
    return mix(tint, vec3f(n), 0.01);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    // Exact clips at the ends of the transition.
    if (p <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (p >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = CLOCK_START + p * CLOCK_SPAN;
    // Rebuild full resolution from the half-resolution grid (one value per 2x2 block) with bilinear weights.
    let size = vec2i(textureDimensions(crisp));
    let h = (vec2f(id.xy) + 0.5) * 0.5 - 0.5;
    let base = floor(h);
    let f = h - base;
    let c0 = clamp(vec2i(base), vec2i(0), (size - 1) / 2);
    let c1 = clamp(vec2i(base) + 1, vec2i(0), (size - 1) / 2);
    let top = mix(textureLoad(crisp, c0 * 2, 0).rgb, textureLoad(crisp, vec2i(c1.x, c0.y) * 2, 0).rgb, f.x);
    let bottom = mix(textureLoad(crisp, vec2i(c0.x, c1.y) * 2, 0).rgb, textureLoad(crisp, c1 * 2, 0).rgb, f.x);
    var col = mix(top, bottom, f.y);
    let k = leak_strength(t);
    if (k > 0.0) {
        let dims = vec2f(textureDimensions(first));
        let light = leak_colour(uv, t, dims);
        let screened = 1.0 - (1.0 - col) * (1.0 - light);
        col = mix(col, screened, k);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
