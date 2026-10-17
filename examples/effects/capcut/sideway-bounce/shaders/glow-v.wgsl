// Sideway Bounce, pass 3: blur the highlights vertically (same grid and jitter as pass 2).

const GLOW_GRID: f32 = 240.0;

fn jitter(a: f32, b: f32) -> f32 {
    var h = fract(vec2f(a, b) * 13.517);
    h += dot(h, h.yx + 22.541);
    return fract((h.x + h.y) * h.y) - 0.5;
}

fn read(q: vec2f) -> vec3f {
    return textureSampleLevel(glow_h, smp, clamp(q, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let stride = globals.size.x / (GLOW_GRID * globals.size.y);
    var sum = read(uv);
    var total = 1.0;
    for (var i = 1; i <= 2; i++) {
        let d = f32(i);
        let w = exp(-d * d / 2.0);
        let dn = uv + vec2f(0.0, (d + jitter(d + uv.x + 0.223, d * uv.y)) * stride);
        let up = uv - vec2f(0.0, (d + jitter(d + uv.x + 0.569, d * uv.y)) * stride);
        sum += (read(dn) + read(up)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
