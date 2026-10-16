// The first clip eases back into a mirrored, RGB-split zoom blur and flares bright, then fades over the second clip settling in from a zoom.

// The whole transition spans this many seconds of animation time.
const SPAN: f32 = 2.0;
const NEAR_LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(u: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(c.y, c.w, 0.5 * (lo + hi));
}

// Value moving from `a` to `b` between times t0 and t1 (held outside that span).
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, ease(x, c));
}

fn mirror01(q: vec2f) -> vec2f {
    return abs(((q - 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
}

// Weight of the red / green / blue tints along the tap run (x = 0 red, 0.5 green, 1 blue).
fn spectrum(x: f32) -> vec3f {
    return vec3f(clamp(1.0 - abs(x) / 0.5, 0.0, 1.0),
                 clamp(1.0 - abs(x - 0.5) / 0.5, 0.0, 1.0),
                 clamp(1.0 - abs(x - 1.0) / 0.5, 0.0, 1.0));
}

// Zoom blur from scale `za` to `zb` around the centre, each tap tinted along the spectrum.
fn split_zoom(tex: texture_2d<f32>, uv: vec2f, za: f32, zb: f32) -> vec3f {
    let centre = vec2f(0.5);
    let gap = zb - za;
    let taps = floor(max(80.0 * abs(gap) * sqrt(length(uv - centre)) * 4.0, 6.0));
    let d = uv - centre;
    var lit = vec3f(0.0);
    var norm = vec3f(0.0);
    for (var k = 0.0; k <= 1024.0; k += 1.0) {
        if (k > taps) { break; }
        let f = k / taps;
        var shade: f32;
        if (za > zb) {
            shade = pow(clamp(1.0 - f, 0.001, 1.0), 1.0 + (za - zb) * 2.0);
        } else {
            shade = pow(clamp(f, 0.001, 1.0), 1.0 + gap * 2.0);
        }
        let tint = spectrum(1.0 - f) * shade;
        let q = mirror01(mix(d / za + centre, d / zb + centre, f));
        lit += textureSampleLevel(tex, smp, q, 0.0).rgb * tint;
        norm += tint;
    }
    return lit / max(norm, vec3f(1e-6));
}

// Brightness lift: maps the slider through two linear ranges, then 1 - (1 - c)^(1 + 5 i).
fn brighten(c: vec3f, v: f32) -> vec3f {
    var i = 0.3 * v;
    if (v > 0.7) { i = 0.6333 * v - 0.2333; }
    if (i <= 0.0) { return c; }
    return clamp(1.0 - pow(max(1.0 - c, vec3f(0.0)), vec3f(1.0 + i * 5.0)), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;

    // Incoming clip: zooms down from 120 % while its own split blur relaxes.
    let s_in = keyed(t, 1.0, 1.966667, 1.2, 1.0, vec4f(0.010345, 0.091065, 0.125080, 1.0));
    let blur_in = keyed(t, 1.0, 1.433333, 1.1, 1.0, NEAR_LINEAR);
    let p_in = (uv - 0.5) / s_in + 0.5;
    let under = split_zoom(second, p_in, 1.0, blur_in);

    // Outgoing clip: shrinks to 90 % (mirrored at the edges), blurs, then fades out.
    var c = under;
    let fade = select(keyed(t, 1.0, 1.433333, 0.5, 0.0, NEAR_LINEAR),
                      keyed(t, 0.966667, 1.0, 1.0, 0.5, NEAR_LINEAR), t < 1.0);
    if (fade > 0.0) {
        let s_out = keyed(t, 0.0, 0.966667, 1.0, 0.9, vec4f(0.733619, 0.0, 0.989655, 1.0));
        let blur_out = keyed(t, 0.5, 0.966667, 1.0, 0.9, NEAR_LINEAR);
        let p_out = mirror01((uv - 0.5) / s_out + 0.5);
        let top = split_zoom(first, p_out, 1.0, blur_out);
        c = top * fade + under * (1.0 - fade);
    }

    // Flash that peaks as the clips cross.
    let flash = select(keyed(t, 0.966667, 1.433333, 1.0, 0.0, vec4f(0.1666667, 0.1666667, 0.05, 1.0)),
                       keyed(t, 0.5, 0.966667, 0.0, 1.0, vec4f(0.55, 0.0, 0.8333333, 0.8333333)), t < 0.966667);
    gpufx_write(id, vec4f(brighten(c, flash), 1.0));
}
