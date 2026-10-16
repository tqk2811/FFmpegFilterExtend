// Heat Flash, pass 1: keep the parts of the visible clip that rise above the glow threshold.
//
// Scene clock: progress 0..1 covers 0.4..1.7333 s; the second clip covers the first from SWAP on.

const START: f32 = 0.4;
const LENGTH: f32 = 1.333333;
const SWAP: f32 = 0.933333;

fn threshold(t: f32) -> f32 {
    if (t >= SWAP) { return 0.0041667; }
    return 0.05 * clamp((t - 0.6) / 0.366667, 0.0, 1.0);
}

// Excess of a channel over the threshold, rescaled to 0..1.
fn over(v: f32, th: f32) -> f32 {
    if (v <= th) { return 0.0; }
    return (v - th) / (1.0 - th);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = START + clamp(params.progress, 0.0, 1.0) * LENGTH;
    var c: vec3f;
    if (t < SWAP) { c = textureSampleLevel(first, smp, uv, 0.0).rgb; }
    else { c = textureSampleLevel(second, smp, uv, 0.0).rgb; }
    let th = threshold(t);
    // The colour keeps its hue; its strength is the summed excess over the threshold.
    let k = (over(c.r, th) + over(c.g, th) + over(c.b, th)) / max(c.r + c.g + c.b, 1e-6);
    gpufx_write(id, vec4f(c * k, 1.0));
}
