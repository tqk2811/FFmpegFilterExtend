// Sideway Bounce, pass 2: keep the parts brighter than half and blur them horizontally.
//
// The glow is worked out on a grid GLOW_GRID texels wide; one blur step spans one grid texel.

const GLOW_GRID: f32 = 240.0;
const CUTOFF: f32 = 0.5;

fn highlights(q: vec2f) -> vec3f {
    let c = textureSampleLevel(shaken, smp, clamp(q, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
    let over = max((c - CUTOFF) / (1.0 - CUTOFF), vec3f(0.0));
    return c * (over.r + over.g + over.b) / max(c.r + c.g + c.b, 1e-6);
}

// Small per-tap jitter (+-0.5 texel) that hides the grid.
fn jitter(a: f32, b: f32) -> f32 {
    var h = fract(vec2f(a, b) * 13.517);
    h += dot(h, h.yx + 22.541);
    return fract((h.x + h.y) * h.y) - 0.5;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let stride = 1.0 / GLOW_GRID;
    var sum = highlights(uv);
    var total = 1.0;
    for (var i = 1; i <= 2; i++) {
        let d = f32(i);
        let w = exp(-d * d / 2.0);
        let r = uv + vec2f((d + jitter(d + uv.x + 0.199, d * uv.y)) * stride, 0.0);
        let l = uv - vec2f((d + jitter(d + uv.x + 0.677, d * uv.y)) * stride, 0.0);
        sum += (highlights(r) + highlights(l)) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
