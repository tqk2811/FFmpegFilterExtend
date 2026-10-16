// Heat Flash, pass 3: blur the highlights vertically with the same per-channel Gaussian widths as pass 2.

const GRID: f32 = 240.0;
const WIDTHS: vec3f = vec3f(24.0, 28.8, 33.6);
const CAP_TAPS: f32 = 30.0;

fn jitter(a: f32, b: f32) -> f32 {
    var f = fract(vec2f(a, b) * 13.517);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y) - 0.5;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let up = vec2f(uv.x, 1.0 - uv.y);
    // One grid texel is square, so vertically it spans width / GRID output pixels too.
    let texel = vec2f(0.0, -globals.size.x / (GRID * globals.size.y));
    let spacing = max(1.0, WIDTHS.z / CAP_TAPS);
    let spread = 2.0 * (WIDTHS / 2.4) * (WIDTHS / 2.4);
    var sum = textureSampleLevel(glow_h, smp, uv, 0.0).rgb;
    var total = vec3f(1.0);
    var d = 1.0;
    for (var i = 0; i < 128; i++) {
        if (d > WIDTHS.z || d > CAP_TAPS * spacing) { break; }
        let w = step(vec3f(d), WIDTHS) * exp(-vec3f(d * d) / spread);
        let fwd = d + spacing * jitter(d + up.x + 0.223, d * up.y);
        let back = d + spacing * jitter(d + up.x + 0.569, d * up.y);
        let a = textureSampleLevel(glow_h, smp, uv + texel * fwd, 0.0).rgb;
        let b = textureSampleLevel(glow_h, smp, uv - texel * back, 0.0).rgb;
        sum += (a + b) * w;
        total += 2.0 * w;
        d += spacing;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
