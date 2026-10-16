// Thermal Imaging 3, pass 4: subtract the boosted glow from the picture and fade that look in and out.

const GAIN: f32 = 4.9;
const GRID: f32 = 240.0;
const IN_START: f32 = 0.133333;
const IN_END: f32 = 0.333333;
const OUT_START: f32 = 0.633333;
const OUT_END: f32 = 0.8;

fn strength(t: f32) -> f32 {
    if (t <= IN_START || t >= OUT_END) { return 0.0; }
    if (t < IN_END) { return (t - IN_START) / (IN_END - IN_START); }
    if (t < OUT_START) { return 1.0; }
    return 1.0 - (t - OUT_START) / (OUT_END - OUT_START);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let base = textureSampleLevel(scene, smp, uv, 0.0).rgb;
    let k = strength(clamp(params.progress, 0.0, 1.0));
    // Exact clips at the ends: outside the glow window the scene pass already is the plain clip.
    if (k <= 0.0) { gpufx_write(id, vec4f(base, 1.0)); return; }
    // The glow grid sits in the top-left corner of its texture; stretch it back over the frame.
    let grid = min(GRID, globals.size.x);
    let cells = vec2f(grid, max(floor(grid * globals.size.y / globals.size.x), 1.0));
    let cell = clamp(uv * cells, vec2f(0.5), cells - 0.5);
    let halo = textureSampleLevel(glow, smp, cell / globals.size, 0.0).rgb * GAIN;
    let looked = abs(halo - clamp(base, vec3f(0.0), vec3f(1.0)));
    gpufx_write(id, vec4f(clamp(mix(base, looked, k), vec3f(0.0), vec3f(1.0)), 1.0));
}
