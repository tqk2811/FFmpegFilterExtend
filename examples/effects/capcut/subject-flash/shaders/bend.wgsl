// Subject flash, step 1: the clip twists about its vertical axis with mirrored edges.

const SPAN: f32 = 2.866657;
const SWITCH_AT: f32 = 1.433333;
const EASE_IO = vec4f(0.3333333, 0.0, 0.6666667, 1.0);

fn timeline_now() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

// Cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1), x solved by bisection.
fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(e.x, e.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(e.y, e.w, 0.5 * (lo + hi));
}

// One eased ramp from v0 (before t0) to v1 (after t1).
fn ramp(t: f32, t0: f32, t1: f32, v0: f32, v1: f32) -> f32 {
    if (t < t0) { return v0; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(EASE_IO, (t - t0) / (t1 - t0)));
}

// The outgoing clip twists away about the vertical axis, then the incoming one twists back.
fn twist(t: f32) -> f32 {
    if (t < SWITCH_AT) { return ramp(t, 1.1, 1.433333, 0.0, 84.0); }
    return ramp(t, 1.433333, 1.766667, 84.0, 0.0);
}

fn mirror(p: vec2f) -> vec2f {
    return abs((p + vec2f(1.0)) - 2.0 * floor((p + vec2f(1.0)) * 0.5) - vec2f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = timeline_now();
    let turn = radians(twist(t));
    // Offset from the centre (y up), split at its foot on a nearly vertical axis, turned about that foot.
    let rel = vec2f(uv.x - 0.5, 0.5 - uv.y);
    let axis = radians(-0.01);
    let steep = tan(axis + 1.5707963);
    let flat = tan(axis);
    let foot_x = (rel.y - flat * rel.x) / (steep - flat);
    let foot = vec2f(foot_x, foot_x * steep);
    let d = rel - foot;
    let c = cos(turn);
    let s = sin(turn);
    let moved = vec2f(c * d.x - s * d.y, s * d.x + c * d.y) + foot + vec2f(0.5);
    let q = mirror(vec2f(moved.x, 1.0 - moved.y));
    var col: vec4f;
    if (t < SWITCH_AT) { col = textureSampleLevel(first, smp, q, 0.0); }
    else { col = textureSampleLevel(second, smp, q, 0.0); }
    gpufx_write(id, vec4f(col.rgb, 1.0));
}
