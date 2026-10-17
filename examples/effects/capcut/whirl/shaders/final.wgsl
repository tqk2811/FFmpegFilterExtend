// Whirl, step 2: the card (drawn at reduced resolution, exposure-pulsed) over the burned, flashed first clip.

const SPAN: f32 = 0.933333;
const SLATE = vec3f(0.172549, 0.250980, 0.278431);
const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

// Cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1), x solved by bisection.
fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(e.x, e.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(e.y, e.w, 0.5 * (lo + hi));
}

fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, e: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(e, (t - t0) / (t1 - t0)));
}

fn card_stops(t: f32) -> f32 {
    var v = key(-1.7, t, 0.133333, 0.233333, -1.7, 0.3, LINEAR);
    v = key(v, t, 0.233333, 0.266667, 0.3, -0.4, LINEAR);
    v = key(v, t, 0.266667, 0.3, -0.4, 0.25, vec4f(0.184986044, -0.227675131, 0.575291107, 1.607404988));
    v = key(v, t, 0.3, 0.333333, 0.25, -1.9, vec4f(0.340590089, 0.147263088, 0.703305424, 1.0));
    return key(v, t, 0.333333, 0.533333, -1.9, 0.0, vec4f(0.33333333, 0.0, 0.415623231, 1.001136502));
}

fn back_stops(t: f32) -> f32 {
    let v = key(0.0, t, 0.0, 0.3, 0.0, 0.9, LINEAR);
    return key(v, t, 0.3, 0.733333, 0.9, 0.0, LINEAR);
}

fn burn_amount(t: f32) -> f32 {
    return key(0.0, t, 0.0, 0.3, 0.0, 22.0, vec4f(0.542647832, 0.00546926, 0.82365265, 1.0)) / 100.0;
}

fn sharpness(t: f32) -> f32 {
    return key(0.4, t, 0.63, 0.933333, 0.4, 1.0, LINEAR);
}

// Exposure in stops, applied in linear light (gamma 2.2).
fn expose(c: vec3f, stops: f32) -> vec3f {
    return clamp(c * exp2(stops / 2.2), vec3f(0.0), vec3f(1.0));
}

fn color_burn(top: f32, base: f32) -> f32 {
    if (base >= 1.0) { return 1.0; }
    if (top <= 0.0) { return 0.0; }
    return 1.0 - min(1.0, (1.0 - base) / top);
}

fn card_pixel(cell: vec2i, grid: vec2f) -> vec4f {
    let c = clamp(cell, vec2i(0), vec2i(grid) - vec2i(1));
    let at = (vec2f(c) + vec2f(0.5)) / grid * globals.size;
    let px = clamp(vec2i(at), vec2i(0), vec2i(globals.size) - vec2i(1));
    return textureLoad(card, px, 0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;

    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let burned = vec3f(color_burn(SLATE.r, a.r), color_burn(SLATE.g, a.g), color_burn(SLATE.b, a.b));
    let back = expose(mix(a, burned, burn_amount(t)), back_stops(t));

    // The card is rendered on a coarser grid, then stretched back with bilinear filtering.
    let grid = max(floor(globals.size * sharpness(t)), vec2f(1.0));
    let q = uv * grid - vec2f(0.5);
    let cell = vec2i(floor(q));
    let f = q - floor(q);
    let top = mix(card_pixel(cell, grid), card_pixel(cell + vec2i(1, 0), grid), f.x);
    let bottom = mix(card_pixel(cell + vec2i(0, 1), grid), card_pixel(cell + vec2i(1, 1), grid), f.x);
    let front = mix(top, bottom, f.y);
    let lit = expose(front.rgb, card_stops(t));

    var c = lit + back * (1.0 - front.a);
    if (t >= 0.1 && t < 0.466667) { c = expose(c, 0.04); }
    gpufx_write(id, vec4f(c, 1.0));
}
