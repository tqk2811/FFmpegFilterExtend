// TV flickers, step 1: vertical gaussian smear of the current clip (first, then second from the midpoint) and a desaturation dip.

// Curves over the transition, 121 rows from progress 0 to 1:
// x = saturation change, y = vertical smear strength, z = sharpening (0..1), w = scanline opacity (percent).
// Table derivation: each column is the original's keyframed track (saturation, directional blur,
// sharpen strength, scanline layer opacity) evaluated with its cubic-bezier easing at 121 evenly
// spaced progress values from 0 to 1; rows are interpolated linearly at run time.
const CURVES = array<vec4f, 121>(
    vec4f(-0.0, 0.0, 0.0, 0.0001), vec4f(-0.0009, 0.0, 0.0009, 0.1829), vec4f(-0.0037, 0.0, 0.0033, 0.7334),
    vec4f(-0.008, 0.0, 0.0073, 1.591), vec4f(-0.014, 0.0, 0.0128, 2.8053), vec4f(-0.0216, 0.0, 0.0198, 4.329),
    vec4f(-0.0303, 0.0, 0.0281, 6.0675), vec4f(-0.0407, 0.0, 0.0377, 8.141), vec4f(-0.0519, 0.0, 0.0486, 10.3719),
    vec4f(-0.0646, 0.0, 0.0607, 12.9196), vec4f(-0.0784, 0.0, 0.0739, 15.68), vec4f(-0.0926, 0.0, 0.0883, 18.5164),
    vec4f(-0.1082, 0.0, 0.1037, 21.6369), vec4f(-0.1239, 0.0, 0.1201, 24.7833), vec4f(-0.1409, 0.0, 0.1375, 28.1883),
    vec4f(-0.1585, 0.0, 0.1568, 31.7093), vec4f(-0.1759, 0.0, 0.1759, 35.1859), vec4f(-0.1944, 0.0, 0.1958, 38.8773),
    vec4f(-0.2124, 0.0, 0.2164, 42.4815), vec4f(-0.2313, 0.0, 0.2376, 46.2677), vec4f(-0.2504, 0.0, 0.2595, 50.0732),
    vec4f(-0.2687, 0.0, 0.2819, 53.7323), vec4f(-0.2876, 0.0, 0.3048, 57.5185), vec4f(-0.3056, 0.0, 0.3281, 61.1227),
    vec4f(-0.3241, 0.0, 0.3519, 64.8141), vec4f(-0.3421, 0.0, 0.3759, 68.428), vec4f(-0.3591, 0.0, 0.4003, 71.8117),
    vec4f(-0.3761, 0.0, 0.4248, 75.2167), vec4f(-0.3918, 0.0, 0.4495, 78.3631), vec4f(-0.4074, 0.0, 0.4744, 81.4836),
    vec4f(-0.4221, 0.0, 0.5007, 84.4299), vec4f(-0.4354, 0.0, 0.5256, 87.0804), vec4f(-0.4481, 0.0, 0.5505, 89.6281),
    vec4f(-0.4593, 0.0, 0.5752, 91.859), vec4f(-0.4697, 0.0, 0.5997, 93.9325), vec4f(-0.4787, 0.0, 0.6241, 95.7351),
    vec4f(-0.486, 0.0, 0.6481, 97.1947), vec4f(-0.492, 0.0, 0.6719, 98.409), vec4f(-0.4963, 0.0, 0.6952, 99.2666),
    vec4f(-0.4991, 0.0, 0.7181, 99.8171), vec4f(-0.5, 0.0002, 0.7405, 100.0), vec4f(-0.4998, 2.2001, 0.7624, 100.0),
    vec4f(-0.4991, 8.4158, 0.7836, 100.0), vec4f(-0.498, 18.2026, 0.8042, 100.0), vec4f(-0.4965, 31.1157, 0.8241, 100.0),
    vec4f(-0.4946, 47.0399, 0.8432, 100.0), vec4f(-0.4924, 64.9108, 0.8625, 100.0), vec4f(-0.4899, 84.565, 0.8799, 100.0),
    vec4f(-0.487, 105.5578, 0.8963, 100.0), vec4f(-0.4841, 127.4445, 0.9117, 100.0), vec4f(-0.4806, 150.2197, 0.9261, 100.0),
    vec4f(-0.4767, 172.5555, 0.9393, 100.0), vec4f(-0.4729, 194.4422, 0.9514, 100.0), vec4f(-0.4685, 215.435, 0.9623, 100.0),
    vec4f(-0.4642, 235.0892, 0.9719, 100.0), vec4f(-0.4593, 253.2897, 0.9802, 100.0), vec4f(-0.4545, 268.8843, 0.9872, 100.0),
    vec4f(-0.4495, 281.7974, 0.9927, 100.0), vec4f(-0.4443, 291.5842, 0.9967, 100.0), vec4f(-0.4384, 297.7999, 0.9991, 100.0),
    vec4f(-0.4328, 299.9998, 1.0, 99.9999), vec4f(-0.427, 299.7401, 0.9991, 99.9134), vec4f(-0.421, 299.0013, 0.9967, 99.6671),
    vec4f(-0.4149, 297.7999, 0.9927, 99.2666), vec4f(-0.4086, 296.1522, 0.9872, 98.7174), vec4f(-0.4021, 294.0748, 0.9802, 98.0249),
    vec4f(-0.3955, 291.5842, 0.9719, 97.1947), vec4f(-0.3887, 288.6967, 0.9623, 96.2322), vec4f(-0.3818, 285.429, 0.9514, 95.143),
    vec4f(-0.3748, 281.7974, 0.9393, 93.9325), vec4f(-0.3676, 277.8185, 0.9261, 92.6062), vec4f(-0.3604, 273.5086, 0.9117, 91.1695),
    vec4f(-0.353, 268.8843, 0.8963, 89.6281), vec4f(-0.3456, 263.9621, 0.8799, 87.9874), vec4f(-0.338, 258.7584, 0.8625, 86.2528),
    vec4f(-0.3304, 252.9601, 0.8432, 84.32), vec4f(-0.3227, 247.2287, 0.8241, 82.4096), vec4f(-0.3149, 241.2663, 0.8042, 80.4221),
    vec4f(-0.307, 235.0892, 0.7836, 78.3631), vec4f(-0.2992, 228.714, 0.7624, 76.238), vec4f(-0.2912, 222.1571, 0.7405, 74.0524),
    vec4f(-0.2832, 215.435, 0.7181, 71.8117), vec4f(-0.2745, 208.5642, 0.6952, 69.5214), vec4f(-0.2665, 201.5611, 0.6719, 67.187),
    vec4f(-0.2584, 194.4422, 0.6481, 64.8141), vec4f(-0.2496, 187.224, 0.6241, 62.408), vec4f(-0.2416, 179.9229, 0.5997, 59.9743),
    vec4f(-0.2335, 172.5555, 0.5752, 57.5185), vec4f(-0.2248, 165.1382, 0.5505, 55.0461), vec4f(-0.216, 157.6874, 0.5256, 52.5625),
    vec4f(-0.2081, 149.7803, 0.4993, 49.9268), vec4f(-0.1994, 142.3126, 0.4744, 47.4375), vec4f(-0.1908, 134.8618, 0.4495, 44.9539),
    vec4f(-0.1823, 127.4445, 0.4248, 42.4815), vec4f(-0.1738, 120.0771, 0.4003, 40.0257), vec4f(-0.1655, 112.776, 0.3759, 37.592),
    vec4f(-0.1572, 105.5578, 0.3519, 35.1859), vec4f(-0.1483, 98.4389, 0.3281, 32.813), vec4f(-0.1403, 91.4358, 0.3048, 30.4786),
    vec4f(-0.1317, 84.565, 0.2819, 28.1883), vec4f(-0.1233, 77.8429, 0.2595, 25.9476), vec4f(-0.115, 71.286, 0.2376, 23.762),
    vec4f(-0.107, 64.9108, 0.2164, 21.6369), vec4f(-0.0991, 58.7337, 0.1958, 19.5779), vec4f(-0.0908, 52.7713, 0.1759, 17.5904),
    vec4f(-0.0828, 47.0399, 0.1568, 15.68), vec4f(-0.0751, 41.2416, 0.1375, 13.7472), vec4f(-0.0677, 36.0379, 0.1201, 12.0126),
    vec4f(-0.0601, 31.1157, 0.1037, 10.3719), vec4f(-0.0528, 26.4914, 0.0883, 8.8305), vec4f(-0.0459, 22.1815, 0.0739, 7.3938),
    vec4f(-0.039, 18.2026, 0.0607, 6.0675), vec4f(-0.0326, 14.571, 0.0486, 4.857), vec4f(-0.0264, 11.3033, 0.0377, 3.7678),
    vec4f(-0.0204, 8.4158, 0.0281, 2.8053), vec4f(-0.0151, 5.9252, 0.0198, 1.9751), vec4f(-0.0103, 3.8478, 0.0128, 1.2826),
    vec4f(-0.0064, 2.2001, 0.0073, 0.7334), vec4f(-0.003, 0.9987, 0.0033, 0.3329), vec4f(-0.0008, 0.2599, 0.0009, 0.0866),
    vec4f(0.0, 0.0, 0.0, 0.0)
);

fn curves(p: f32) -> vec4f {
    let f = clamp(p, 0.0, 1.0) * 120.0;
    let i = min(u32(floor(f)), 119u);
    return mix(CURVES[i], CURVES[i + 1u], f - f32(i));
}

// Reference side used to scale blur sizes, so the look holds across aspect ratios.
fn ref_side() -> f32 {
    return max(min(globals.size.x, globals.size.y), 0.5 * max(globals.size.x, globals.size.y));
}

// Tap count for a given smear strength, as a function of the strength band.
fn smear_taps(s: f32) -> f32 {
    var n: f32;
    if (s <= 10.0) { n = 0.8 * s; }
    else if (s <= 50.0) { n = (0.7 * s + 2.0) * 0.78; }
    else if (s <= 200.0) { n = (0.5 * s + 10.0) * 0.66; }
    else if (s <= 500.0) { n = (0.25 * s + 60.0) * 0.7; }
    else { n = (0.125 * s + 100.0) * 0.8; }
    if (n < 2.0) { n = floor(n + 0.5); }
    return n;
}

fn source(uv: vec2f) -> vec4f {
    // The swap happens just after the midpoint (the first clip still owns progress 0.5).
    if (params.progress <= 0.5) { return textureSampleLevel(first, smp, uv, 0.0); }
    return textureSampleLevel(second, smp, uv, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let k = curves(params.progress);
    var c = source(uv);
    let n = smear_taps(k.y);
    if (k.y > 0.0 && n > 1e-5) {
        let reach = k.y / 1000.0;
        let sigma = reach / 3.0;
        let stride = reach / n * ref_side() / globals.size.y;
        var acc = c;
        var total = 1.0;
        // Peak strength in the table is 300 -> 94.5 taps per side (~190 fetches per pixel).
        for (var i = 1; i <= 96; i++) {
            let fi = f32(i);
            if (fi > n) { break; }
            let d = fi * stride;
            let w = exp(-0.5 * d * d / (sigma * sigma));
            if (uv.y - d >= 0.0) { acc += source(vec2f(uv.x, uv.y - d)) * w; total += w; }
            if (uv.y + d <= 1.0) { acc += source(vec2f(uv.x, uv.y + d)) * w; total += w; }
        }
        c = acc / total;
    }
    // Saturation: mix towards luma with weight (1 + change).
    let keep = 1.0 + k.x;
    let luma = vec3f(0.20854, 0.702086, 0.089374) * (1.0 - keep);
    let g = vec3f(dot(c.rgb, luma + vec3f(keep, 0.0, 0.0)), dot(c.rgb, luma + vec3f(0.0, keep, 0.0)), dot(c.rgb, luma + vec3f(0.0, 0.0, keep)));
    gpufx_write(id, vec4f(clamp(g, vec3f(0.0), vec3f(1.0)), 1.0));
}
