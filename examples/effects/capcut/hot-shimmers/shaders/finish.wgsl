// Hot Shimmers, pass 4: add the highlight glow, then smear everything with a fading zoom blur.
//
// The zoom blur streams toward a point on the frame's bottom edge; its strength and
// the glow intensity follow the same scene clock as pass 1.

const START: f32 = 0.466667;
const END: f32 = 1.433333;
const GLOW_PEAK: f32 = 0.4;
const ZOOM_PEAK: f32 = 13.0;
const ZOOM_SCALE: f32 = 200.0;
const ZOOM_FADE: f32 = 0.965;
const MAX_STEPS: i32 = 128;

fn glow_amount(t: f32) -> f32 {
    if (t < 0.6 || t >= 1.3) { return 0.0; }
    if (t < 0.733333) { return GLOW_PEAK * (t - 0.6) / 0.133333; }
    if (t < 1.133333) { return GLOW_PEAK; }
    return GLOW_PEAK * clamp(1.0 - (t - 1.133333) / 0.133334, 0.0, 1.0);
}

fn zoom_amount(t: f32) -> f32 {
    if (t < 0.6 || t >= 1.3) { return 0.0; }
    if (t < 0.933333) { return ZOOM_PEAK * (t - 0.6) / 0.333333; }
    return ZOOM_PEAK * clamp(1.0 - (t - 0.933333) / 0.333334, 0.0, 1.0);
}

fn shaded(q: vec2f, gain: f32) -> vec3f {
    let base = textureSampleLevel(warped, smp, q, 0.0).rgb;
    let halo = textureSampleLevel(glow, smp, q, 0.0).rgb;
    return base + clamp(halo * gain, vec3f(0.0), vec3f(1.0));
}

fn mirror1(v: f32) -> f32 {
    let a = abs(v);
    return abs(floor(ceil(a) * 0.5) * 2.0 - a);
}

fn jitter(p: vec2f) -> f32 {
    var f = fract(p * 13.517);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = START + clamp(params.progress, 0.0, 1.0) * (END - START);
    let g = glow_amount(t);
    let strength = zoom_amount(t) / ZOOM_SCALE;

    var color = shaded(uv, g);
    if (strength > 0.0) {
        let focus = vec2f(0.5, 1.0);
        let reach = (uv - focus) * strength;
        let steps = min(8.0 * 20.0 * (0.9 * length(reach) + 0.1) + 5.0, f32(MAX_STEPS));
        let step = reach / steps;
        let fade = pow(pow(ZOOM_FADE, 50.0), 1.0 / steps);
        let origin = uv + step * (0.5 * (jitter(uv) * 2.0 - 1.0));
        var sum = color;
        var total = 1.0;
        var w = 1.0;
        for (var i = 1; i <= MAX_STEPS; i++) {
            let k = f32(i);
            if (k > steps) { break; }
            w *= fade;
            var s = origin - step * k;
            s = vec2f(mirror1(s.x), mirror1(s.y));
            sum += shaded(s, g) * w;
            total += w;
        }
        color = sum / total;
    }
    gpufx_write(id, vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), 1.0));
}
