// A silver bar sweeps down the frame; above it the second clip is uncovered, below it the first clip remains.

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * x1 + 3.0 * inv * s * s * x2 + s * s * s;
        if (bx < x) { lo = s; } else { hi = s; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * y1 + 3.0 * inv * s * s * y2 + s * s * s;
}

// Brightness of the bar across its height (0 = top rim, 1 = bottom rim): thin dark rims,
// a brushed-metal body that peaks just below the middle.
fn bar_shade(v: f32) -> f32 {
    let knots = array<vec2f, 17>(
        vec2f(0.0, 0.54), vec2f(0.009, 0.475), vec2f(0.018, 0.53), vec2f(0.027, 0.66),
        vec2f(0.036, 0.78), vec2f(0.054, 0.81), vec2f(0.09, 0.805), vec2f(0.18, 0.86),
        vec2f(0.27, 0.90), vec2f(0.36, 0.943), vec2f(0.495, 0.978), vec2f(0.63, 0.946),
        vec2f(0.765, 0.903), vec2f(0.9, 0.886), vec2f(0.955, 0.77), vec2f(0.973, 0.523),
        vec2f(1.0, 0.43));
    var shade = knots[0].y;
    for (var i = 1; i < 17; i++) {
        let a = knots[i - 1];
        let b = knots[i];
        if (v >= a.x && v <= b.x) {
            shade = mix(a.y, b.y, (v - a.x) / (b.x - a.x));
        }
    }
    return shade;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    // Exact clips at the ends of the transition.
    if (t <= 0.0) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    if (t >= 1.0) {
        gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0));
        return;
    }

    // Bar centre travels from just above the frame to just below it (layout in a 720-tall frame).
    // All sizes are height-relative on purpose: the original lays the 1280x111 bar out in a
    // camera whose vertical extent is the frame height and stretches its width by the aspect
    // ratio, so the bar is always full width and 111/720 of the height, in any aspect.
    // At travel 1 its top edge sits at 720.5/720, fully below the frame.
    let travel = clamp((t - 0.066667) / 0.866666, 0.0, 1.0);
    let centre = (-60.0 + 836.0 * bezier_ease(travel, 0.33333, 0.0, 0.0, 1.0)) / 720.0;
    // Everything above the bar already shows the second clip.
    var color = textureSampleLevel(first, smp, uv, 0.0).rgb;
    if (uv.y < centre) {
        color = textureSampleLevel(second, smp, uv, 0.0).rgb;
    }
    let half_height = 55.5 / 720.0;
    let v = (uv.y - (centre - half_height)) / (2.0 * half_height);
    if (v >= 0.0 && v <= 1.0) {
        // Slightly brighter towards the middle of the width.
        let sheen = 0.02 * (1.0 - abs(uv.x - 0.5) * 2.0);
        color = vec3f(bar_shade(v) + sheen - 0.01);
    }
    gpufx_write(id, vec4f(color, 1.0));
}
