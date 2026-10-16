// Push Away 2, pass 3: keep the parts brighter than half and blur them horizontally.
//
// The glow is worked out on a grid GLOW_GRID texels wide (same step vertically), so one
// blur step spans size.x / GLOW_GRID output pixels whatever the frame size. Red, green
// and blue spread over slightly different widths.

const GLOW_GRID: f32 = 360.0;
const KNEE: f32 = 0.5;
const RADII: vec3f = vec3f(1.8, 2.16, 2.52);

fn highlights(q: vec2f) -> vec3f {
    let c = textureSampleLevel(spun, smp, clamp(q, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
    let over = max(c - KNEE, vec3f(0.0)) / (1.0 - KNEE);
    let gain = (over.r + over.g + over.b) / max(c.r + c.g + c.b, 0.000001);
    return c * gain;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let stride = max(globals.size.x / GLOW_GRID, 1.0) / globals.size.x;
    let spread = 2.0 * (RADII / 2.4) * (RADII / 2.4);
    var sum = highlights(uv);
    var total = vec3f(1.0);
    for (var i = 1; i <= 2; i++) {
        let d = f32(i);
        let w = step(vec3f(d), RADII) * exp(-vec3f(d * d) / spread);
        let side = highlights(uv + vec2f(d * stride, 0.0)) + highlights(uv - vec2f(d * stride, 0.0));
        sum += side * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
