// A window opens from the centre of the first clip, pushing its four sides outward, and reveals the second clip zooming up inside it.

// The whole transition spans this many seconds of animation time.
const SPAN: f32 = 0.6;

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

// Distance of the window edge from each border, in uv units (0.5 = closed, <= 0 = gone).
fn edge_offset(t: f32) -> f32 {
    if (t < 0.4) {
        return keyed(t, 0.0, 0.4, 0.5, 123.473566 / 1280.0, vec4f(0.851746, 0.022064, 0.810982, 0.857893));
    }
    return keyed(t, 0.4, 0.6, 123.473566 / 1280.0, -2.0 / 1280.0, vec4f(0.189715, 0.293579, 0.182653, 1.022287));
}

// Zoom of the second clip inside the window.
fn inner_zoom(t: f32) -> f32 {
    if (t < 0.4) {
        return keyed(t, 0.0, 0.4, 0.0, 0.85, vec4f(0.679026, 0.048740, 0.885537, 0.846257));
    }
    return keyed(t, 0.4, 0.53, 0.85, 1.0, vec4f(0.188488, 0.466256, 0.253752, 0.901072));
}

// Samples the first clip with y measured from the bottom edge.
fn clip_a(p: vec2f) -> vec3f {
    return textureSampleLevel(first, smp, clamp(vec2f(p.x, 1.0 - p.y), vec2f(0.0), vec2f(1.0)), 0.0).rgb;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Band layout is built with y pointing up.
    let up = vec2f(uv.x, 1.0 - uv.y);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SPAN;
    let o = edge_offset(t);
    let zoom = inner_zoom(t);

    // Four bands of the first clip, each shifted outward toward its own border.
    let far = 1.0 - o;
    let top_band = step(far, up.y);
    let right_band = step(far, up.x);
    let bottom_band = 1.0 - step(o, up.y);
    let left_band = 1.0 - step(o, up.x);
    let push = o - 0.5;
    let pull = far - 0.5;
    var c = clip_a(up + vec2f(0.0, push)) * top_band;
    c = mix(c, clip_a(up + vec2f(push, 0.0)) * right_band, right_band);
    c = mix(c, clip_a(up + vec2f(0.0, pull)) * bottom_band, bottom_band);
    c = mix(c, clip_a(up + vec2f(pull, 0.0)) * left_band, clamp(left_band - top_band, 0.0, 1.0));

    // The second clip, zoomed about the centre, fills the opening.
    let hole = 1.0 - clamp(top_band + right_band + bottom_band + left_band, 0.0, 1.0);
    let q = (uv - 0.5) / max(zoom, 1e-4) + 0.5;
    let inner = textureSampleLevel(second, smp, clamp(q, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
    gpufx_write(id, vec4f(mix(c, inner, hole), 1.0));
}
