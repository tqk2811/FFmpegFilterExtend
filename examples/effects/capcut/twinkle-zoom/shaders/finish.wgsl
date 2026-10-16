// Twinkle Zoom, pass 5: the bokeh is drawn on a coarser grid and stretched back.

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

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends of the transition.
    if (params.progress <= 0.0) {
        gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0));
        return;
    }
    if (params.progress >= 1.0) {
        gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0));
        return;
    }
    let strength = pow(bokeh_amount(params.progress), 0.35);
    let coarse = max(floor(globals.size * mix(1.0, 0.35, strength)), vec2f(1.0));
    // Read the bokeh at the centres of the four nearest coarse cells and blend them bilinearly.
    let g = uv * coarse - 0.5;
    let base = floor(g);
    let f = g - base;
    let lo = clamp((base + 0.5) / coarse, vec2f(0.0), vec2f(1.0));
    let hi = clamp((base + 1.5) / coarse, vec2f(0.0), vec2f(1.0));
    let c00 = textureSampleLevel(bokeh, smp, lo, 0.0);
    let c10 = textureSampleLevel(bokeh, smp, vec2f(hi.x, lo.y), 0.0);
    let c01 = textureSampleLevel(bokeh, smp, vec2f(lo.x, hi.y), 0.0);
    let c11 = textureSampleLevel(bokeh, smp, hi, 0.0);
    let c = mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
    gpufx_write(id, vec4f(c.rgb, 1.0));
}
