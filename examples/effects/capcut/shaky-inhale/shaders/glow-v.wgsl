// Vertical half of the glow blur: the bright parts of the picture bloom into white light.

// Glow curves over progress (45 even steps): brightness threshold, glow amount, extra lift.
const GLOW_LEVEL = array<f32, 45>(
    1.0, 0.96013, 0.93941, 0.92765, 0.92092, 0.91718, 0.91515, 0.91396,
    0.91294, 0.9115, 0.90914, 0.90535, 0.89959, 0.8913, 0.87978, 0.8642,
    0.77573, 0.07773, 0.18355, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    1.0, 1.0, 1.0, 1.0, 1.0,
);

const GLOW_AMOUNT = array<f32, 45>(
    6.8212e-14, 0.019091, 0.038182, 0.057273, 0.076364, 0.095454, 0.11455, 0.13364,
    0.15273, 0.17182, 0.19091, 0.21, 0.22909, 0.24818, 0.26727, 0.28636,
    1.1465, 3.7576, 3.9974, 3.9848, 3.9605, 3.9233, 3.8716, 3.8036,
    3.717, 3.6091, 3.4767, 3.3155, 3.1208, 2.8865, 2.606, 2.2737,
    1.8884, 1.4628, 1.0326, 0.65036, 0.35581, 0.15809, 0.045777, 0.0020732,
    0.0, 0.0, 0.0, 0.0, 0.0,
);

const GLOW_LIFT = array<f32, 45>(
    2.2737e-13, 0.063636, 0.12727, 0.19091, 0.25455, 0.31818, 0.38182, 0.44545,
    0.50909, 0.57273, 0.63636, 0.7, 0.76364, 0.82727, 0.89091, 0.95454,
    1.4576, 2.869, 2.9981, 2.9886, 2.9704, 2.9425, 2.9037, 2.8527,
    2.7877, 2.7068, 2.6075, 2.4867, 2.3406, 2.1648, 1.9545, 1.7053,
    1.4163, 1.0971, 0.77448, 0.48777, 0.26686, 0.11857, 0.034333, 0.0015549,
    0.0, 0.0, 0.0, 0.0, 0.0,
);
// How strongly the glow amount and the lift brighten the picture, and the threshold scale.
const AMOUNT_GAIN: f32 = 0.08;
const LIFT_GAIN: f32 = 0.15;
const LEVEL_SCALE: f32 = 0.1;
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
    let c = textureLoad(streaks, p, 0).rgb;
    let level = curve(GLOW_LEVEL, params.progress);
    let gain = curve(GLOW_AMOUNT, params.progress) * AMOUNT_GAIN + curve(GLOW_LIFT, params.progress) * LIFT_GAIN;
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
    // The glow is white: only the brightness of the halo above the threshold counts.
    let bright = max(dot(halo, vec3f(0.299, 0.587, 0.114)) - level * LEVEL_SCALE, 0.0);
    gpufx_write(id, vec4f(c + vec3f(bright * gain), 1.0));
}
