// Bubble Blur, pass 5: ring-shaped bokeh on both softened clips (bright spots bloom into bubbles), then a short cross-fade between them.

// Number of taps on the golden-angle spiral.
const SPIRAL_TAPS: i32 = 98;
// Weight kept by taps inside the rim (0 = only the rim lights up, giving hollow bubbles).
const INNER_WEIGHT: f32 = 0.0;
// How strongly bright taps dominate the average.
const HIGHLIGHT_GAIN: f32 = 539.35;

// Spiral radius reached after all taps; taps are judged relative to it.
fn spiral_end() -> f32 {
    var r = 1.0;
    for (var i = 0; i < SPIRAL_TAPS; i++) { r += 1.0 / r; }
    return r;
}

fn bokeh_first(uv: vec2f, base: vec2f, aspect: f32, rim: f32) -> vec3f {
    var dir = base;
    var r = 1.0;
    var acc = vec3f(0.0);
    var wsum = vec3f(0.0);
    for (var i = 0; i < SPIRAL_TAPS; i++) {
        dir = turn(dir, aspect);
        let c = textureSampleLevel(first_v, smp, uv + (r - 1.0) * mix(1.5, 1.0, r / rim) * dir, 0.0).rgb;
        acc += c * tap_weight(c, r / rim);
        wsum += tap_weight(c, r / rim);
        r += 1.0 / r;
    }
    return acc / wsum;
}

fn bokeh_second(uv: vec2f, base: vec2f, aspect: f32, rim: f32) -> vec3f {
    var dir = base;
    var r = 1.0;
    var acc = vec3f(0.0);
    var wsum = vec3f(0.0);
    for (var i = 0; i < SPIRAL_TAPS; i++) {
        dir = turn(dir, aspect);
        let c = textureSampleLevel(second_v, smp, uv + (r - 1.0) * mix(1.5, 1.0, r / rim) * dir, 0.0).rgb;
        acc += c * tap_weight(c, r / rim);
        wsum += tap_weight(c, r / rim);
        r += 1.0 / r;
    }
    return acc / wsum;
}

// Rotate the tap direction by the golden angle, in aspect-corrected space.
fn turn(d: vec2f, aspect: f32) -> vec2f {
    let q = vec2f(d.x * aspect, d.y);
    let r = vec2f(-0.73735 * q.x - 0.67539 * q.y, 0.67539 * q.x - 0.73735 * q.y);
    return vec2f(r.x / aspect, r.y);
}

// Bright taps weigh far more; taps fade out at the very edge and, inside the rim, drop to INNER_WEIGHT.
fn tap_weight(c: vec3f, d: f32) -> vec3f {
    let w = pow(c, vec3f(9.0)) * HIGHLIGHT_GAIN + 0.4;
    return w * (1.0 - smoothstep(0.9, 1.0, d)) * (INNER_WEIGHT + (1.0 - INNER_WEIGHT) * smoothstep(0.8, 0.9, d));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let p = clamp(params.progress, 0.0, 1.0);
    let strength = 1.25 * (1.0 - abs(2.0 * p - 1.0));
    // The bubble radius is measured on a half-size grid whose short side is 360 px.
    let grid = globals.size * (360.0 / min(globals.size.x, globals.size.y));
    let aspect = grid.x / grid.y;
    let long_ratio = max(grid.x, grid.y) / min(grid.x, grid.y);
    let base = vec2f(0.0, 0.35 * strength * long_ratio) / grid;
    let rim = spiral_end();
    // The clips swap with a linear cross-fade between 40 % and 60 %.
    let fade = clamp((p - 0.4) / 0.2, 0.0, 1.0);
    var col: vec3f;
    if (fade <= 0.0) {
        col = bokeh_first(uv, base, aspect, rim);
    } else if (fade >= 1.0) {
        col = bokeh_second(uv, base, aspect, rim);
    } else {
        col = mix(bokeh_first(uv, base, aspect, rim), bokeh_second(uv, base, aspect, rim), fade);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
