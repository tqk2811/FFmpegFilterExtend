// Thermal Imaging 3, pass 1: key the second clip in over the first by brightness, brightest areas first.
//
// `progress` is the scene clock (0..1). Between KEY_START and KEY_END the luma cut-off
// slides from CUT_HIGH down to 0, with a soft ramp SOFT wide below it; the first clip
// stays underneath until KEY_END.

const KEY_START: f32 = 0.333333;
const KEY_END: f32 = 0.633333;
const CUT_HIGH: f32 = 200.0 / 255.0;
const SOFT: f32 = 30.0 / 255.0;
const LUMA: vec3f = vec3f(0.3, 0.588235, 0.111765);

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (t < KEY_START) { gpufx_write(id, vec4f(a, 1.0)); return; }
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    if (t >= KEY_END) { gpufx_write(id, vec4f(b, 1.0)); return; }
    let cut = CUT_HIGH * (1.0 - (t - KEY_START) / (KEY_END - KEY_START));
    let lo = cut - SOFT;
    let keep = clamp((dot(b, LUMA) - lo) / (cut - lo + 1e-5), 0.0, 1.0);
    gpufx_write(id, vec4f(b * keep + a * (1.0 - keep), 1.0));
}
