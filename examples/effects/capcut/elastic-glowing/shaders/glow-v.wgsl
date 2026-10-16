// Vertical half of the glow blur, added on top of the picture as a white bloom.

// Glow strengths over progress (45 even steps).
const SHINE = array<f32, 45>(
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.12499, 0.4, 0.675,
    0.8, 0.76875, 0.7, 0.63125, 0.6, 0.50625, 0.30001, 0.093756,
    1.6401e-10, 0.0, 0.0, 0.0, 0.0,
);

const BLOOM = array<f32, 45>(
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0060154, 0.021875, 0.044296, 0.07, 0.095703,
    0.11812, 0.13398, 0.14, 0.13914, 0.13687, 0.13343, 0.12895, 0.12348,
    0.11696, 0.10924, 0.1, 0.057001, 1.5864e-10, 0.0, 0.0, 0.0,
    1.5619e-12, 0.014497, 0.035, 0.055502, 0.07, 0.055503, 0.035001, 0.014498,
    7.6527e-11, 0.0, 0.0, 0.0, 0.0,
);
// How strongly each glow term brightens the picture (the bloom term grows with the cube
// of its curve, so it only floods the frame right at the swap).
const SHINE_GAIN: f32 = 0.3;
const BLOOM_GAIN: f32 = 2000.0;
// Glow radius as a gaussian sigma, in pixels of a 1080-pixel-high frame.
const GLOW_SIGMA: f32 = 24.0;

fn curve(t: array<f32, 45>, p: f32) -> f32 {
    var a = t;
    let k = clamp(p, 0.0, 1.0) * 44.0;
    let i = u32(floor(k));
    return mix(a[i], a[min(i + 1u, 44u)], k - floor(k));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let p = vec2i(id.xy);
    let c = textureLoad(soft, p, 0).rgb;
    let bloom = curve(BLOOM, params.progress);
    let gain = curve(SHINE, params.progress) * SHINE_GAIN + bloom * bloom * bloom * BLOOM_GAIN;
    if (gain <= 0.0) {
        gpufx_write(id, vec4f(c, 1.0));
        return;
    }
    let size = vec2i(textureDimensions(glow_h));
    let sigma = GLOW_SIGMA * globals.size.y / 1080.0;
    let r = i32(min(ceil(sigma * 2.5), 96.0));
    var sum = vec3f(0.0);
    var wsum = 0.0;
    for (var i = -r; i <= r; i++) {
        let w = exp(-f32(i * i) / (2.0 * sigma * sigma));
        sum += w * textureLoad(glow_h, clamp(p + vec2i(0, i), vec2i(0), size - 1), 0).rgb;
        wsum += w;
    }
    let halo = sum / wsum;
    gpufx_write(id, vec4f(c + halo * halo * gain, 1.0));
}
