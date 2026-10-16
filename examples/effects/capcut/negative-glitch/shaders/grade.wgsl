// Negative Glitch, pass 1: pick the clip for the current half, fade it towards its negative and push the exposure.

const SPAN: f32 = 2.0; // the timeline runs 0..2, the cut is at 1

// Ease-in-out key (both handles at a third): exactly a smoothstep in time.
fn ramp(t: f32, t0: f32, t1: f32, v0: f32, v1: f32) -> f32 {
    let u = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(v0, v1, u * u * (3.0 - 2.0 * u));
}

fn invert_amount(t: f32) -> f32 {
    if (t < 1.1) { return ramp(t, 0.780176, 0.952507, 0.0, 1.0); }
    return ramp(t, 1.1, 1.272298, 1.0, 0.0);
}

fn stops(t: f32) -> f32 {
    if (t < 1.00166) { return ramp(t, 0.903255, 1.00166, 0.0, 4.2); }
    return ramp(t, 1.00166, 1.1, 4.2, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    var c = textureSampleLevel(first, smp, uv, 0.0).rgb;
    if (t >= 1.0) { c = textureSampleLevel(second, smp, uv, 0.0).rgb; }
    c = mix(c, vec3f(1.0) - c, invert_amount(t));
    // Exposure in linear light (gamma 2.2), then back.
    let lin = pow(max(c, vec3f(0.0)), vec3f(2.2)) * exp2(stops(t));
    c = clamp(pow(lin, vec3f(1.0 / 2.2)), vec3f(0.0), vec3f(1.0));
    gpufx_write(id, vec4f(c, 1.0));
}
