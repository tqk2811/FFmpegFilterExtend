// Push Away 2, pass 2: a short spin blur around the frame centre while the clips change.

const SPAN: f32 = 1.110011;
// The spin, glow and flash are active up to this scene time.
const FX_END: f32 = 0.96001;
const MAX_TAPS: i32 = 96;

fn ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let s = 0.5 * (lo + hi);
        let r = 1.0 - s;
        let bx = 3.0 * r * r * s * c.x + 3.0 * r * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * c.y + 3.0 * r * s * s * c.w + s * s * s;
}

fn key(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return a; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

// Blur strength (negative = sweep the other way), 0 outside the swap.
fn spin_amount(t: f32) -> f32 {
    if (t < 0.540005) {
        return key(t, 0.270003, 0.540005, 0.0, -3.0, vec4f(1.0, -0.027539682, 0.772877509, 1.0));
    }
    return key(t, 0.540005, 0.750008, -3.0, 0.0, vec4f(0.33333333, 0.0, 0.0, 0.95678117));
}

fn turn_about_centre(p: vec2f, angle: f32, stretch: f32) -> vec2f {
    var d = p - 0.5;
    d.y /= stretch;
    d = vec2f(cos(angle) * d.x - sin(angle) * d.y, sin(angle) * d.x + cos(angle) * d.y);
    d.y *= stretch;
    return d + 0.5;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let base = textureSampleLevel(layer, smp, uv, 0.0);
    let t = params.progress * SPAN;
    let strength = spin_amount(t) / 200.0;
    if (t > FX_END || strength == 0.0) {
        gpufx_write(id, base);
        return;
    }
    // Tap count grows with the distance from the centre so long arcs stay smooth.
    let reach = length((uv - 0.5) * strength);
    let taps = 15.0 * 11.4 * (0.9 * reach + 0.1) + 20.0;
    // Picture coordinates run downward, so the sweep turns the opposite way numerically.
    let step_angle = -6.2831853 * strength / taps;
    let stretch = globals.size.x / globals.size.y;
    var sum = base.rgb;
    var weight = 1.0;
    for (var k = 1; k <= MAX_TAPS; k++) {
        if (f32(k) > taps) { break; }
        let q = turn_about_centre(uv, f32(k) * step_angle, stretch);
        // Taps off the picture count as black, as in the reference (it darkens the corners).
        weight += 1.0;
        if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
            sum += textureSampleLevel(layer, smp, q, 0.0).rgb;
        }
    }
    gpufx_write(id, vec4f(sum / weight, 1.0));
}
