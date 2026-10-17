// The first clip twists shut row by row around a vertical axis, pinching to a point, and the second clip untwists out of it.

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * x1 + 3.0 * inv * s * s * x2 + s * s * s;
        if (bx < x) { lo = s; } else { hi = s; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * y1 + 3.0 * inv * s * s * y2 + s * s * s;
}

// Value animated from `a` to `b` between times t0 and t1 with the given easing curve.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, curve: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, curve.x, curve.y, curve.z, curve.w));
}

// Hard-light style mix of a flat tone over one channel.
fn overlay_tone(base: vec3f, tone: f32) -> vec3f {
    let low = 2.0 * base * tone;
    let high = 1.0 - 2.0 * (1.0 - base) * (1.0 - tone);
    return select(high, low, base < vec3f(0.5));
}

// Edge shading on the twisting card: a dark rim along its top edge and a bright rim on
// its right edge, strongest halfway through the twist. `tc` is the card coordinate.
fn rim_shade(color: vec3f, tc: vec2f, amount: f32) -> vec3f {
    let up = 1.0 - tc.y;
    var dark = 0.0;
    if (up >= 0.5) { dark = (1.0 - pow(4.0 * up * (1.0 - up), 0.25)) * amount; }
    var light = 0.0;
    if (tc.x >= 0.5) { light = (1.0 - pow(4.0 * tc.x * (1.0 - tc.x), 0.25)) * amount; }
    var c = color * (1.0 - 0.5 * dark);
    c = mix(c, overlay_tone(c, 0.0), dark);
    c = mix(c, overlay_tone(c, 0.0), dark);
    c = mix(c, vec3f(1.0), 0.5 * light);
    c = mix(c, overlay_tone(c, 1.0), light);
    c = mix(c, overlay_tone(c, 1.0), light);
    return c;
}

// Horizontal position (in texture space) of the twist axis.
const AXIS_X: f32 = 0.48016;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    // Exact clips at the ends of the transition.
    if (t <= 0.0) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    if (t >= 1.0) {
        gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0));
        return;
    }

    let twist = keyed(t, 0.0, 0.966667, 0.0, 1.0, vec4f(0.3, 0.0, 0.7, 1.0));
    // The whole picture dips to 95 % and comes back while the card twists.
    let ease = vec4f(0.33333, 0.0, 0.66667, 1.0);
    let zoom = select(keyed(t, 0.633333, 0.966667, 0.95, 1.0, ease),
                      keyed(t, 0.0, 0.333333, 1.0, 0.95, ease), t < 0.333333);
    let q = 0.5 + (uv - 0.5) / zoom;

    // Rotation of this row about the vertical axis; rows twist more the further they are
    // from the anchored edge (top edge in the first half, bottom edge in the second).
    let row = 1.0 - 2.0 * q.y;
    var angle: f32;
    var flipped: bool;
    if (twist <= 0.5) {
        angle = (row - 1.0) * twist * 3.14159265;
        flipped = false;
    } else {
        angle = (-row - 1.0) * (1.0 - twist) * 3.14159265;
        flipped = true;
    }
    let width = cos(angle);
    var color = vec3f(0.0);
    if (abs(width) > 1e-4 && all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
        let tc = vec2f(AXIS_X + (q.x - AXIS_X) / abs(width), q.y);
        if (tc.x >= 0.0 && tc.x <= 1.0) {
            // Facing rows show the front clip, rows turned past 90 degrees its back side.
            let use_second = (width > 0.0) == flipped;
            if (use_second) {
                color = textureSampleLevel(second, smp, tc, 0.0).rgb;
            } else {
                color = textureSampleLevel(first, smp, tc, 0.0).rgb;
            }
            color = rim_shade(color, tc, sin(twist * 3.14159265));
        }
    }
    gpufx_write(id, vec4f(color, 1.0));
}
