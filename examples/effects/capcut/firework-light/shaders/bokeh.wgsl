// Firework Light, pass 4: disc-shaped bokeh blur that blooms the bright sparkles into round discs.
//
// The blur is worked out on a smaller grid (down to 40% of the frame at full strength) that
// fills the top-left corner of this pass's output; the last pass scales it back up.

const SPAN: f32 = 2.0;
// Weight boost of bright taps: weight = c^9 * BRIGHT_GAIN + 0.4.
const BRIGHT_GAIN: f32 = 539.45;
// Share of the filled disc taps (and of their peak) against the rim taps.
const FILL_SHARE: f32 = 0.5;
// How far the result is pushed towards the brightest tap.
const PEAK_PULL: f32 = 0.5;
// Overall size factor of the blur.
const SIZE: f32 = 0.7;

fn blur_amount(t: f32) -> f32 {
    if (t <= 0.16666667 || t >= 1.83333333) { return 0.0; }
    if (t < 1.0) { return 35.0 * (t - 0.16666667) / 0.83333333; }
    return 35.0 * (1.83333333 - t) / 0.83333333;
}

fn tap_weight(c: vec4f) -> vec4f {
    return pow(c, vec4f(9.0)) * BRIGHT_GAIN + 0.4;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let strength = blur_amount(params.progress * SPAN) / 79.0;
    let soft_strength = pow(strength, 0.35);
    let grid = floor(globals.size * mix(1.0, 0.4, soft_strength));
    if (f32(id.x) >= grid.x || f32(id.y) >= grid.y) {
        gpufx_write(id, vec4f(0.0));
        return;
    }
    let uv = (vec2f(id.xy) + 0.5) / grid;
    if (strength < 0.01) {
        gpufx_write(id, textureSampleLevel(soft, smp, uv, 0.0));
        return;
    }

    let screen = globals.size / min(globals.size.x, globals.size.y) * 720.0;
    let unit = 2.0 * vec2f(7.5 * strength * SIZE) / screen;
    let spacing = mix(2.0, 0.5, strength);
    var brightest = vec4f(0.0);
    var acc = vec4f(0.0);
    var total = vec4f(0.4);

    // Filled disc of radius 11 on a square lattice (only once the blur is strong enough).
    let reach = max(5.0, 12.0 / spacing);
    if (strength >= 0.3) {
        for (var i = 0; i < 30; i++) {
            let fi = f32(i);
            if (fi > reach) { break; }
            for (var j = 0; j < 30; j++) {
                let fj = f32(j);
                if (fj > reach) { break; }
                let o = vec2f(mix(-11.0, 11.0, fi / reach), mix(-11.0, 11.0, fj / reach));
                if (dot(o, o) > 121.0) { continue; }
                let c = textureSampleLevel(soft, smp, uv - 0.5 * o * unit, 0.0);
                brightest = max(brightest, c * mix(0.7, 1.0, FILL_SHARE));
                let w = tap_weight(c) * FILL_SHARE;
                acc += w * c;
                total += w;
            }
        }
    }

    // Rim of the disc.
    let rim = max(15.0, 34.0 / spacing);
    let turn = 6.28 / rim;
    let cs = cos(turn);
    let sn = sin(turn);
    var o = vec2f(11.0, 0.0);
    for (var k = 0; k < 70; k++) {
        if (f32(k) > rim) { break; }
        o = vec2f(o.x * cs + o.y * sn, -o.x * sn + o.y * cs);
        let c = textureSampleLevel(soft, smp, uv - 0.5 * o * unit, 0.0);
        brightest = max(brightest, c);
        let w = tap_weight(c);
        acc += w * c;
        total += w;
    }

    let result = clamp(acc / total, vec4f(0.0), vec4f(1.0));
    gpufx_write(id, mix(result, brightest, clamp(result * PEAK_PULL, vec4f(0.0), vec4f(1.0))));
}
