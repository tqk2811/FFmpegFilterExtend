// Big wave, step 5: keep the highlights (above 0.7) in linear light and blur them sideways.

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

// Glow strength: rises to 1.1 at the clip switch, then fades.
fn glow_now(t: f32) -> f32 {
    var v = key(0.0, t, 0.0, 0.366667, 0.0, 1.1, vec4f(0.61458638, 0.0, 0.999, 1.0));
    v = key(v, t, 0.366667, 0.8, 1.1, 0.0, vec4f(0.001, 0.0, 0.389181461, 1.0));
    return v;
}

// Wide gaussian: 33 taps spread over GLOW_REACH of the frame height each way.
const GLOW_REACH: f32 = 0.12;
const GLOW_TAPS: i32 = 16;

fn highlight(c: vec3f) -> vec3f {
    let lin = c * c;
    let l = dot(c, vec3f(0.2126, 0.7152, 0.0722));
    return lin * step(0.7, l);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    if (glow_now(timeline_now()) <= 0.0) { gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0)); return; }
    let uv = gpufx_uv(id);
    let stride = vec2f(GLOW_REACH * globals.size.y / globals.size.x / f32(GLOW_TAPS), 0.0);
    var acc = vec3f(0.0);
    var total = 0.0;
    for (var i = -GLOW_TAPS; i <= GLOW_TAPS; i++) {
        let x = f32(i) / f32(GLOW_TAPS);
        let w = exp(-x * x * 4.5);
        acc += highlight(textureSampleLevel(prismed, smp, clamp(uv + stride * f32(i), vec2f(0.0), vec2f(1.0)), 0.0).rgb) * w;
        total += w;
    }
    gpufx_write(id, vec4f(acc / total, 1.0));
}
