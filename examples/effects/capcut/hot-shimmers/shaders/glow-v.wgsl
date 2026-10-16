// Hot Shimmers, pass 3: vertical half of the highlight blur.

const GLOW_GRID: f32 = 240.0;
const GLOW_RADIUS: f32 = 13.333333;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Same pixel pitch as the horizontal pass: the grid keeps the frame's aspect ratio.
    let stride = max(globals.size.x / GLOW_GRID, 1.0) / globals.size.y;
    let spread = 2.0 * pow(GLOW_RADIUS / 2.4, 2.0);
    var sum = textureSampleLevel(glow_h, smp, uv, 0.0).rgb;
    var total = 1.0;
    for (var i = 1; i <= 13; i++) {
        let d = f32(i);
        let w = exp(-d * d / spread);
        let up = clamp(uv + vec2f(0.0, d * stride), vec2f(0.0), vec2f(1.0));
        let down = clamp(uv - vec2f(0.0, d * stride), vec2f(0.0), vec2f(1.0));
        sum += (textureSampleLevel(glow_h, smp, up, 0.0).rgb + textureSampleLevel(glow_h, smp, down, 0.0).rgb) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
