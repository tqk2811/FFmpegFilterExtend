// Push Away 2, pass 4: finish the glow vertically, screen it over the picture and add a white flash.

const SPAN: f32 = 1.110011;
const FX_END: f32 = 0.96001;
const GLOW_GRID: f32 = 360.0;
const RADII: vec3f = vec3f(1.8, 2.16, 2.52);

fn ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let s = 0.5 * (lo + hi);
        let r = 1.0 - s;
        let bx = 3.0 * r * r * s * c.x + 3.0 * r * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * c.y + 3.0 * r * s * s * c.w + s * s * s;
}

fn key(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return a; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

fn glow_gain(t: f32) -> f32 {
    if (t < 0.510005) {
        return key(t, 0.360004, 0.510005, 0.0, 1.2, vec4f(1.0, -0.01530028, 0.66666667, 1.0));
    }
    return key(t, 0.510005, 0.750008, 1.2, 0.0, vec4f(0.521605485, 0.000054693, 0.251634423, 0.980884743));
}

// Strength of the white light added on top (0..1).
fn flash(t: f32) -> f32 {
    if (t < 0.570006) {
        return key(t, 0.300003, 0.570006, 0.0, 16.0, vec4f(0.981631948, -0.032491226, 0.79284447, 1.0)) / 100.0;
    }
    return key(t, 0.570006, 0.96001, 16.0, 0.0, vec4f(0.04981712, -0.000259311, 0.334699495, 1.0)) / 100.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so the transition starts and finishes on the plain inputs.
    if (params.progress <= 0.0) {
        gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0));
        return;
    }
    if (params.progress >= 1.0) {
        gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0));
        return;
    }
    let t = params.progress * SPAN;
    var c = textureSampleLevel(spun, smp, uv, 0.0).rgb;

    let gain = glow_gain(t);
    if (t <= FX_END && gain > 0.0) {
        let stride = max(globals.size.x / GLOW_GRID, 1.0) / globals.size.y;
        let spread = 2.0 * (RADII / 2.4) * (RADII / 2.4);
        var sum = textureSampleLevel(glow_h, smp, uv, 0.0).rgb;
        var total = vec3f(1.0);
        for (var i = 1; i <= 2; i++) {
            let d = f32(i);
            let w = step(vec3f(d), RADII) * exp(-vec3f(d * d) / spread);
            let up = textureSampleLevel(glow_h, smp, clamp(uv - vec2f(0.0, d * stride), vec2f(0.0), vec2f(1.0)), 0.0).rgb;
            let down = textureSampleLevel(glow_h, smp, clamp(uv + vec2f(0.0, d * stride), vec2f(0.0), vec2f(1.0)), 0.0).rgb;
            sum += (up + down) * w;
            total += 2.0 * w;
        }
        let halo = sum / total * gain;
        c = 1.0 - (1.0 - clamp(c, vec3f(0.0), vec3f(1.0))) * (1.0 - halo);
    }
    c += vec3f(flash(t));
    gpufx_write(id, vec4f(clamp(c, vec3f(0.0), vec3f(1.0)), 1.0));
}
