// Twinkle Zoom, pass 2: soften the picture vertically with a Gaussian whose reach follows the bokeh strength.

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * x1 + 3.0 * inv * s * s * x2 + s * s * s;
        let dx = 3.0 * inv * inv * x1 + 6.0 * inv * s * (x2 - x1) + 3.0 * s * s * (1.0 - x2);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * y1 + 3.0 * inv * s * s * y2 + s * s * s;
}

// Bokeh strength 0..1: rises to its peak at the midpoint, gone again by 5/6 of the way.
fn bokeh_amount(p: f32) -> f32 {
    var taps = 0.0;
    if (p < 0.5) {
        taps = 35.0 * bezier_ease(p / 0.5, 0.33333, 0.0, 0.66667, 1.0);
    } else if (p < 0.833333) {
        taps = 35.0 * (1.0 - bezier_ease((p - 0.5) / 0.333333, 0.33333, 0.0, 0.66667, 1.0));
    }
    return taps / 79.0;
}

// Gaussian bell with a spread of 4 (normalised density).
fn bell(x: f32) -> f32 {
    return 0.39894 * exp(-0.5 * x * x / 16.0) / 4.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let strength = pow(bokeh_amount(params.progress), 0.35);
    let taps = 22.0 * strength * 0.7;
    // One tap is one pixel of a frame whose short side is 720 px.
    let step = vec2f(0.0, 1.0) * min(globals.size.x, globals.size.y) / (globals.size * 720.0);
    let w0 = bell(0.0);
    var sum = textureSampleLevel(blended, smp, uv, 0.0) * w0;
    var total = w0;
    for (var i = 1; i <= 32; i++) {
        let t = f32(i);
        if (t > taps) { break; }
        let w = bell(t / taps * 15.0);
        sum += (textureSampleLevel(blended, smp, uv + step * t, 0.0) + textureSampleLevel(blended, smp, uv - step * t, 0.0)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, clamp(sum / total, vec4f(0.0), vec4f(1.0)));
}
