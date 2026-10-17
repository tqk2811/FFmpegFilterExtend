// Zoom blur of the second clip toward a moving centre, fading out as the clip settles.

// Length of the animation timeline in seconds.
const SPAN: f32 = 1.0833333;

// Cubic Bezier easing through (0,0), (c.x,c.y), (c.z,c.w), (1,1): bisect for x, return y.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

fn span01(t: f32, t0: f32, t1: f32) -> f32 { return clamp((t - t0) / (t1 - t0), 0.0, 1.0); }

// Blur amount (200 = all the way to the centre) at time t.
fn zoom_amount(t: f32) -> f32 {
    if (t < 0.416667) { return mix(47.0, 27.0, span01(t, 0.208333, 0.416667)); }
    return mix(27.0, 0.0, bezier_ease(span01(t, 0.416667, 1.041667), vec4f(0.166667, 0.166667, 0.0, 1.0)));
}

// Blur centre in bottom-up texture coordinates.
fn zoom_centre(t: f32) -> vec2f {
    let far = vec2f(1.8304846, 1.7924879);
    let corner = vec2f(-0.0162177, -0.0149448);
    if (t < 0.416667) { return mix(far, corner, span01(t, 0.333333, 0.416667)); }
    return mix(corner, vec2f(0.5), bezier_ease(span01(t, 0.416667, 1.041667), vec4f(0.166667, 0.166667, 0.0, 1.0)));
}

// Per-pixel jitter in [0, 1).
fn grain(p: vec2f) -> f32 {
    let f = fract(p * 13.517);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

// Sample in bottom-up texture coordinates; outside the frame is transparent.
fn fetch(q: vec2f) -> vec4f {
    if (q.x < 0.0 || q.y < 0.0 || q.x > 1.0 || q.y > 1.0) { return vec4f(0.0); }
    return textureSampleLevel(second, smp, vec2f(q.x, 1.0 - q.y), 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let strength = zoom_amount(t) / 200.0;
    let base = textureSampleLevel(second, smp, uv, 0.0);
    // The clip is invisible before it starts flying in, so skip the work there.
    if (strength <= 0.0 || t < 0.291667) { gpufx_write(id, base); return; }
    let q = vec2f(uv.x, 1.0 - uv.y);
    let reach = (q - zoom_centre(t)) * strength;
    let taps = min(8.0 * 20.0 * (0.9 * length(reach) + 0.1) + 5.0, 128.0);
    let stride = reach / taps;
    let start = q + stride * (0.5 * (grain(q) * 2.0 - 1.0));
    var acc = base;
    var total = 1.0;
    for (var k = 1; k <= 128; k++) {
        if (f32(k) > taps) { break; }
        acc += fetch(start - stride * f32(k));
        total += 1.0;
    }
    gpufx_write(id, acc / total);
}
