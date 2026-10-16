// Slide film, step 3: lens distortion that bulges the picture out from the centre, strongest at the switch.

// The animation is laid out over 0.7 s of timeline; the second clip takes over at 0.233333 s.
const TIMELINE: f32 = 0.7;
const SWITCH_AT: f32 = 0.233333;

fn timeline_now() -> f32 { return clamp(params.progress, 0.0, 1.0) * TIMELINE; }

// CSS-like cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1), solved for x by bisection.
fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(x1: f32, y1: f32, x2: f32, y2: f32, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(x1, x2, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(y1, y2, 0.5 * (lo + hi));
}

// One keyframe segment: keeps `cur` before `t0`, eases from v0 to v1 inside, holds v1 after.
fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, e: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(e.x, e.y, e.z, e.w, (t - t0) / (t1 - t0)));
}

const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = timeline_now();
    let uv = gpufx_uv(id);
    var fov = key(0.0, t, 0.0, 0.233333, 0.0, 66.0, vec4f(0.578466983, 0.099587499, 0.750146692, 1.0));
    fov = key(fov, t, 0.233333, 0.7, 66.0, 0.0, vec4f(0.2, 0.0, 0.54, 0.95));
    var q = uv;
    if (fov > 0.01) {
        // Distance in half-widths; a point at r maps back to atan(r * tan(half)) / half (barrel bulge).
        let half = radians(fov) * 0.5;
        let d = (uv - 0.5) * globals.size / (0.5 * globals.size.x);
        let r = length(d);
        if (r > 1e-6) {
            let src = atan(r * tan(half)) / half;
            q = d / r * src * (0.5 * globals.size.x) / globals.size + 0.5;
        }
    }
    var c = vec3f(0.0);
    if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
        c = textureSampleLevel(blurred, smp, q, 0.0).rgb;
    }
    gpufx_write(id, vec4f(c, 1.0));
}
