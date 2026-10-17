// Transform Shimmer, pass 1: cross-fade, the first clip is gone after the first 43% of the move.

const SPAN: f32 = 1.1666667; // scene length in seconds; progress maps onto it
const FADE_END: f32 = 0.5;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let keep = 1.0 - clamp(t / FADE_END, 0.0, 1.0);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    gpufx_write(id, vec4f(mix(b, a, keep), 1.0));
}
