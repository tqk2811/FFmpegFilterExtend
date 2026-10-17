// The first clip dissolves into a foam of wobbly bubbles that shrink away over the second clip.

// Length of the underlying animation, in seconds of foam time.
const SPAN: f32 = 1.9166667;

fn hash21(c: vec2f) -> f32 {
    var q = fract(c * vec2f(123.34, 456.21));
    q += dot(q, q + 45.32);
    return fract(q.x * q.y);
}

fn hash22(c: vec2f) -> vec2f {
    let a = hash21(c);
    return vec2f(a, hash21(c + a * 17.13));
}

// Smooth value noise in [0, 1].
fn value_noise(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let s = f * f * (3.0 - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2f(1.0, 0.0));
    let c = hash21(i + vec2f(0.0, 1.0));
    let d = hash21(i + vec2f(1.0, 1.0));
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

// Three octaves of value noise, normalised to [0, 1].
fn cloud(p: vec2f) -> f32 {
    return (value_noise(p) * 0.57 + value_noise(p * 2.03 + 7.1) * 0.29 + value_noise(p * 4.07 + 3.3) * 0.14);
}

// Coverage of one layer of round bubbles laid on a jittered grid; each bubble shrinks to
// nothing at its own moment. `d_px` is one pixel in these units, for anti-aliasing.
fn bubble_layer(p: vec2f, density: f32, t: f32, start: f32, life: f32, keep: f32, d_px: f32, salt: f32) -> f32 {
    let g = p * density;
    let base = floor(g);
    var cover = 0.0;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let cell = base + vec2f(f32(i), f32(j));
            let h = hash22(cell + salt);
            if (hash21(cell + salt + 3.7) > keep) { continue; }
            let centre = cell + 0.5 + (h - 0.5) * 0.8;
            let size = mix(0.12, 0.45, h.x * h.x);
            let end = start + life * mix(0.45, 1.0, h.y);
            let k = clamp(1.0 - (t - start) / (end - start), 0.0, 1.0);
            let r = size * sqrt(k);
            if (r <= 0.0) { continue; }
            let d = length(g - centre) - r;
            cover = max(cover, clamp(0.5 - d / (d_px * density), 0.0, 1.0));
        }
    }
    return cover;
}

// Mask of the first clip: 1 = first clip, 0 = second clip.
fn foam(uv: vec2f, t: f32) -> f32 {
    let span = min(globals.size.x, globals.size.y);
    var p = (uv - 0.5) * globals.size / span;
    // Gentle turbulent wobble of the whole foam.
    p += (vec2f(value_noise(p * 9.0 + 11.0), value_noise(p * 9.0 + 29.0)) - 0.5) * 0.03;
    let d_px = 1.0 / span;
    // Large merged blobs: the noise level that stays covered rises with time.
    let level = mix(-0.05, 0.92, smoothstep(0.0, 0.95, t));
    let n = cloud(p * 2.6 + 4.0);
    let edge = fwidth_free(n, p);
    let blobs = clamp((n - level) / edge + 0.5, 0.0, 1.0);
    // Holes punched through early, then scattered bubbles that pop later.
    let big = bubble_layer(p, 5.0, t, 0.3, 0.75, 0.55, d_px, 1.0);
    let small = bubble_layer(p, 11.0, t, 0.25, 0.95, 0.5, d_px, 7.0);
    return max(blobs, max(big, small));
}

// Width of one pixel in noise units, estimated without derivatives (compute shader).
fn fwidth_free(n: f32, p: vec2f) -> f32 {
    let span = min(globals.size.x, globals.size.y);
    let dx = cloud((p + vec2f(1.0 / span, 0.0)) * 2.6 + 4.0) - n;
    let dy = cloud((p + vec2f(0.0, 1.0 / span)) * 2.6 + 4.0) - n;
    return max(abs(dx) + abs(dy), 1e-5);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(a, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(b, 1.0)); return; }
    let t = params.progress * SPAN;
    let m = foam(uv, t);
    gpufx_write(id, vec4f(mix(b, a, m), 1.0));
}
