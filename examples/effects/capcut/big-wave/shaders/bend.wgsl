// Big wave, step 1: the first clip bulges out through a fisheye lens, the second one starts pinched and relaxes.

const TIMELINE: f32 = 0.8333333;
const SWITCH_AT: f32 = 0.366667;
const TAU: f32 = 6.2831853;

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

// ---- Fisheye lens: a mesh whose points move by sin(pi u) sin(pi v) along the ray from the centre ----

fn lens_scale(q: vec2f, bend: f32) -> f32 {
    let u = q * 0.5 + 0.5;
    let w = abs(bend) * sin(u.x * 3.1415927) * sin(u.y * 3.1415927);
    if (bend > 0.0) { return mix(1.0, 1.9, w); }
    return mix(1.0, 0.25, w);
}

// The mesh pushes a source point q to q * lens_scale(q); invert that along the ray by bisection.
fn lens(uv: vec2f, bend: f32) -> vec2f {
    if (abs(bend) < 1e-4) { return uv; }
    let p = uv * 2.0 - 1.0;
    let reach = max(abs(p.x), abs(p.y));
    if (reach < 1e-6) { return uv; }
    let edge = p / reach;
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (mid * lens_scale(edge * mid, bend) > reach) { hi = mid; } else { lo = mid; }
    }
    return edge * (0.5 * (lo + hi)) * 0.5 + 0.5;
}

fn bend_now(t: f32) -> f32 {
    if (t < SWITCH_AT) {
        return key(0.0, t, 0.0, 0.366667, 0.0, 100.0, vec4f(1.0, 0.0, 0.999, 1.0)) / 100.0;
    }
    return key(-100.0, t, 0.366667, 0.7, -100.0, 0.0, vec4f(0.001, 0.0, 0.21, 1.0)) / 100.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = timeline_now();
    let q = lens(gpufx_uv(id), bend_now(t));
    var c: vec4f;
    if (t < SWITCH_AT) {
        c = textureSampleLevel(first, smp, q, 0.0);
    } else {
        c = textureSampleLevel(second, smp, q, 0.0);
    }
    gpufx_write(id, vec4f(c.rgb, 1.0));
}
