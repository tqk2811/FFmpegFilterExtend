// Vertical half of the soft blur that peaks while the clips swap.

// Blur strength over progress (45 even steps).
const SOFTEN = array<f32, 45>(
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 14.5, 29.0, 27.754, 24.469, 19.824, 14.5, 9.1758,
    4.5312, 1.2461, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0,
);

// Blur strength to gaussian sigma, in pixels of a 1080-pixel-high frame.
const SIGMA_PER_UNIT: f32 = 0.5;

fn curve(t: array<f32, 45>, p: f32) -> f32 {
    var a = t;
    let k = clamp(p, 0.0, 1.0) * 44.0;
    let i = u32(floor(k));
    return mix(a[i], a[min(i + 1u, 44u)], k - floor(k));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(soft_h));
    let p = vec2i(id.xy);
    let sigma = curve(SOFTEN, params.progress) * SIGMA_PER_UNIT * globals.size.y / 1080.0;
    var c = textureLoad(soft_h, p, 0).rgb;
    if (sigma > 0.3) {
        let r = i32(min(ceil(sigma * 3.0), 96.0));
        var sum = vec3f(0.0);
        var wsum = 0.0;
        for (var i = -r; i <= r; i++) {
            let w = exp(-f32(i * i) / (2.0 * sigma * sigma));
            sum += w * textureLoad(soft_h, clamp(p + vec2i(0, i), vec2i(0), size - 1), 0).rgb;
            wsum += w;
        }
        c = sum / wsum;
    }
    gpufx_write(id, vec4f(c, 1.0));
}
