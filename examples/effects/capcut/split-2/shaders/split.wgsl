// Top and bottom halves slide apart sideways with motion blur, uncovering the second clip.

// Timing curves (cubic bezier control points x1, y1, x2, y2) for each half.
const CURVE_BOTTOM: vec4f = vec4f(0.79, 0.0, 0.17, 0.96);
const CURVE_TOP: vec4f = vec4f(0.77, 0.06, 0.07, 0.99);

// With `overlap` off, only one clip feeds the transition at a time: the first clip for
// the first half of `progress`, the second clip for the rest, in both roles.
fn outgoing_tex_is_second() -> bool {
    return params.overlap == 0u && params.progress >= 0.5;
}

fn incoming_tex_is_first() -> bool {
    return params.overlap == 0u && params.progress < 0.5;
}

// x coordinate of a cubic bezier from (0,0) to (1,1) at curve parameter s.
fn curve_x(k: vec4f, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * k.x * r * r * s + 3.0 * k.z * r * s * s + s * s * s;
}

// Solve curve_x(s) = x for s by bisection. The curve parameter itself (not the curve's
// y value) is used as the eased position; that is what gives this transition its feel.
fn curve_param(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 14; n++) {
        let mid = (lo + hi) * 0.5;
        if (curve_x(k, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return (lo + hi) * 0.5;
}

fn rgb_of(tex: texture_2d<f32>, q: vec2f) -> vec3f {
    return textureSampleLevel(tex, smp, q, 0.0).rgb;
}

// Colour of one point for a half that has travelled `amount` (0..1) across the frame.
// The top half (y <= 0.5) moves right with the second clip entering from the left;
// the bottom half moves left with the second clip entering from the right.
fn split_frame(q: vec2f, amount: f32) -> vec3f {
    let is_top = step(q.y, 0.5);
    let is_bottom = 1.0 - is_top;
    // Where the boundary between the two clips sits on this row.
    let edge = amount * is_top + (1.0 - amount) * is_bottom;
    var q_out = q;
    var q_in = q;
    q_out.x += -edge * is_top + (1.0 - edge) * is_bottom;
    q_in.x += (1.0 - edge) * is_top - edge * is_bottom;
    var outgoing = rgb_of(first, q_out);
    if (outgoing_tex_is_second()) { outgoing = rgb_of(second, q_out); }
    var incoming = rgb_of(second, q_in);
    if (incoming_tex_is_first()) { incoming = rgb_of(first, q_in); }
    let left_of_edge = step(q.x, edge);
    return mix(outgoing, incoming, left_of_edge) * is_top
         + mix(incoming, outgoing, left_of_edge) * is_bottom;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0);
    // Real length of the transition: turns the per-progress speed into per-second speed.
    let seconds = max(params.duration, 0.01);

    let pos_bottom = curve_param(CURVE_BOTTOM, t);
    let pos_top = curve_param(CURVE_TOP, t);
    // Speed of each half from a forward difference, used as the blur length.
    let h = 0.01;
    var speed_bottom = (curve_param(CURVE_BOTTOM, t + h) - pos_bottom) / h / seconds;
    var speed_top = (curve_param(CURVE_TOP, t + h) - pos_top) / h / seconds;
    // The curves still move at progress 0, which would blur the untouched first clip.
    // At the very ends show the clip itself, so the transition joins its neighbours
    // without a jump.
    if (t <= 0.0 || t >= 1.0) {
        speed_bottom = 0.0;
        speed_top = 0.0;
    }

    let on_bottom = step(0.5, uv.y);
    let on_top = step(uv.y, 0.5);
    let pos = pos_bottom * on_bottom + pos_top * on_top;
    let speed = speed_bottom * on_bottom + speed_top * on_top;

    // Nine samples trailing to the left, spaced by the current speed.
    var acc = vec3f(0.0);
    for (var n = 0; n < 9; n++) {
        acc += split_frame(uv - vec2f(speed * f32(n) * 0.002, 0.0), pos);
    }
    gpufx_write(id, vec4f(acc / 9.0, 1.0));
}
