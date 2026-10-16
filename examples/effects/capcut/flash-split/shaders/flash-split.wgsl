// Hard cut to the second clip with a white flash on the left half just before it and on the right half just after it.

// Scene clock runs from START to END as progress goes 0 -> 1; the cut happens at 1.0.
const START: f32 = 0.366667;
const END: f32 = 1.566667;
const PEAK: f32 = 0.8;

// Left flash: up over one frame from 0.9, held, down over one frame from 1.0.
fn left_flash(t: f32) -> f32 {
    if (t < 0.9 || t >= 1.033333) { return 0.0; }
    if (t < 0.933333) { return PEAK * (t - 0.9) / 0.033333; }
    if (t < 1.0) { return PEAK; }
    return PEAK * (1.0 - (t - 1.0) / 0.033333);
}

// Right flash: up over one frame from the cut, held, then switched off at 1.133333.
fn right_flash(t: f32) -> f32 {
    if (t < 1.0 || t >= 1.133333) { return 0.0; }
    if (t < 1.033333) { return PEAK * (t - 1.0) / 0.033333; }
    return PEAK;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = START + clamp(params.progress, 0.0, 1.0) * (END - START);

    var color = textureSampleLevel(first, smp, uv, 0.0).rgb;
    if (t >= 1.0) { color = textureSampleLevel(second, smp, uv, 0.0).rgb; }
    var flash = right_flash(t);
    if (uv.x < 0.5) { flash = left_flash(t); }
    gpufx_write(id, vec4f(min(color + vec3f(flash), vec3f(1.0)), 1.0));
}
