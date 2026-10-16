// Dramatic vortex, step 1: the first clip grows and spins away; the second clip spins in from 170 degrees.

// Timeline of the animation: 0.366667 s to 1.3 s; the second clip takes over just after 0.833333 s.
const START: f32 = 0.366667;
const TIMELINE: f32 = 0.933333;
const SWITCH_AT: f32 = 0.8334;

fn timeline_now() -> f32 { return START + clamp(params.progress, 0.0, 1.0) * TIMELINE; }

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

fn mirror01(q: vec2f) -> vec2f {
    return abs(((q - 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
}

// Maps an output point to the layer point under it, for a layer turned by `degrees`
// (clockwise on screen) and scaled by `zoom` about the frame centre.
fn unlayer(uv: vec2f, degrees: f32, zoom: f32) -> vec2f {
    let a = -radians(degrees);
    var d = (uv - 0.5) * globals.size;
    d = vec2f(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a)) / zoom;
    return d / globals.size + 0.5;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = timeline_now();
    let uv = gpufx_uv(id);
    var c: vec4f;
    if (t < SWITCH_AT) {
        var zoom = key(100.0, t, 0.366667, 0.633333, 100.0, 110.4, vec4f(0.469618874, 0.020483951, 0.702278614, 0.609619177));
        zoom = key(zoom, t, 0.633333, 0.833333, 110.4, 133.0, vec4f(0.368994411, 0.151131191, 0.47657507, 0.649452688));
        let turn = key(0.0, t, 0.633333, 0.833333, 0.0, -246.0, vec4f(1.0, 0.0014539, 0.95, 0.994743851));
        c = textureSampleLevel(first, smp, mirror01(unlayer(uv, turn, zoom / 100.0)), 0.0);
    } else {
        var turn = key(170.0, t, 0.833333, 0.966667, 170.0, 16.7, vec4f(0.001, -1.96e-7, 0.033271688, 0.74231663));
        turn = key(turn, t, 0.966667, 1.266667, 16.7, 0.0, vec4f(0.122257281, 0.666368294, 0.331502542, 1.012078667));
        c = textureSampleLevel(second, smp, mirror01(unlayer(uv, turn, 1.0)), 0.0);
    }
    gpufx_write(id, vec4f(c.rgb, 1.0));
}
