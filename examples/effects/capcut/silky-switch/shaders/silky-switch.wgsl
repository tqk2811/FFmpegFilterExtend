// The first clip rounds its corners, shrinks and glides off to the left while the second clip slides in from the right and grows to full frame.

// The whole transition spans this many seconds of animation time.
const SPAN: f32 = 2.0;
// Layout reference width; horizontal positions below are in these units.
const REF_W: f32 = 504.0;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var s = x;
    for (var i = 0; i < 10; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        let dx = 3.0 * inv * inv * c.x + 6.0 * inv * s * (c.z - c.x) + 3.0 * s * s * (1.0 - c.z);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Value animated from `a` to `b` between times t0 and t1 with the given easing curve.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, curve: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, curve));
}

// One clip placed with its centre at horizontal offset `cx` (in REF_W units), scaled by
// `scale`, with corners rounded by `corner` (0..256 of half the short side).
// Returns premultiplied colour + coverage.
fn card(tex: texture_2d<f32>, uv: vec2f, cx: f32, scale: f32, corner: f32) -> vec4f {
    let p = vec2f((uv.x - cx / REF_W) / scale + 0.5, (uv.y - 0.5) / scale + 0.5);
    if (any(p < vec2f(0.0)) || any(p > vec2f(1.0))) { return vec4f(0.0); }
    let size = vec2f(globals.size);
    let half_short = min(size.x, size.y) * 0.5;
    let r = half_short * corner / 256.0;
    let soft = half_short * 0.5 * 5.0 / 256.0 + 0.05;
    let half = size * 0.5;
    let q = abs(p * size - half) - (half - vec2f(r));
    let inside = r - (length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0));
    let cover = smoothstep(-soft, soft, inside);
    return vec4f(textureSampleLevel(tex, smp, p, 0.0).rgb, 1.0) * cover;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SPAN;

    let out_x = keyed(t, 0.0, 1.966667, 252.0, -306.0, vec4f(0.5, 0.0, 0.28, 1.0));
    let out_s = keyed(t, 0.0, 0.966667, 1.0, 0.8, vec4f(0.321823, 0.0, 0.045587, 1.0));
    let out_r = keyed(t, 0.0, 0.333333, 0.0, 60.0, vec4f(0.166667, 0.166667, 0.34, 1.0));

    let in_x = keyed(t, 0.0, 1.966667, 810.0, 252.0, vec4f(0.48, 0.0, 0.28, 1.0));
    let in_s = keyed(t, 0.533333, 1.966667, 0.88, 1.0, vec4f(0.166667, 0.166667, 0.63, 1.0));
    let in_r = keyed(t, 1.5, 1.966667, 60.0, 0.0, vec4f(0.5, 0.0, 0.833333, 0.833333));

    let back = card(first, uv, out_x, out_s, out_r);
    let front = card(second, uv, in_x, in_s, in_r);
    // Both cards sit on a black stage; the incoming one is drawn on top.
    let rgb = front.rgb + back.rgb * (1.0 - front.a);
    gpufx_write(id, vec4f(rgb, 1.0));
}
