// Hot Shimmers, pass 2: keep the bright parts of the warped picture and blur them horizontally.
//
// The glow is worked out on a grid GLOW_GRID texels wide, so one blur step spans
// size.x / GLOW_GRID output pixels whatever the frame size.

const GLOW_GRID: f32 = 240.0;
const GLOW_RADIUS: f32 = 13.333333; // grid texels
const KNEE_LOW: f32 = 0.425;
const KNEE_HIGH: f32 = 0.575;

fn highlights(q: vec2f) -> vec3f {
    let c = textureSampleLevel(warped, smp, clamp(q, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
    return smoothstep(vec3f(KNEE_LOW), vec3f(KNEE_HIGH), c);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let stride = max(globals.size.x / GLOW_GRID, 1.0) / globals.size.x;
    let spread = 2.0 * pow(GLOW_RADIUS / 2.4, 2.0);
    var sum = highlights(uv);
    var total = 1.0;
    for (var i = 1; i <= 13; i++) {
        let d = f32(i);
        let w = exp(-d * d / spread);
        sum += (highlights(uv + vec2f(d * stride, 0.0)) + highlights(uv - vec2f(d * stride, 0.0))) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
