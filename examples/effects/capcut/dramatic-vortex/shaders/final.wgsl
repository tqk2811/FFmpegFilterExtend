// Dramatic vortex, step 4: vertical half of the blur, then the exposure flashes.

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

// Gaussian blur size: radius (in frame fractions) per unit of strength.
fn blur_strength(t: f32) -> f32 {
    var v = key(0.0, t, 0.633333, 0.833333, 0.0, 65.0, vec4f(0.3333333, 0.0, 0.6666667, 1.0));
    v = key(v, t, 0.833333, 1.266667, 65.0, 0.0, vec4f(0.3333333, 0.0, 0.477812196, 0.967983824));
    return v / 1000.0;
}

const BLUR_TAPS: i32 = 24;

fn to_linear(c: vec3f) -> vec3f { return pow(max(c, vec3f(0.0)), vec3f(2.2)); }
fn to_gamma(c: vec3f) -> vec3f { return pow(max(c, vec3f(0.0)), vec3f(1.0 / 2.2)); }

// One gaussian pass in linear light, radius `reach` (uv) along `dir`, sigma = radius / 2.5.
fn gauss(tex: texture_2d<f32>, uv: vec2f, dir: vec2f, reach: f32) -> vec3f {
    var acc = vec3f(0.0);
    var total = 0.0;
    for (var i = -BLUR_TAPS; i <= BLUR_TAPS; i++) {
        let x = f32(i) / f32(BLUR_TAPS);
        let w = exp(-0.5 * (x * 2.5) * (x * 2.5));
        let q = clamp(uv + dir * reach * x, vec2f(0.0), vec2f(1.0));
        acc += to_linear(textureSampleLevel(tex, smp, q, 0.0).rgb) * w;
        total += w;
    }
    return acc / total;
}

// Exposure in stops: a slow flash into the switch and a sharp one right after it.
fn exposure_now(t: f32) -> f32 {
    var v = key(0.0, t, 0.366667, 0.7, 0.0, 0.9, vec4f(0.3333333, 0.0, 0.6666667, 1.0));
    v = key(v, t, 0.7, 0.833333, 0.9, 0.1, vec4f(0.3333333, 0.0, 0.6666667, 1.0));
    v = key(v, t, 0.833333, 0.966667, 0.1, 1.0, vec4f(0.3333333, 0.0, 0.882666747, 1.000366207));
    v = key(v, t, 0.966667, 1.266667, 1.0, 0.0, vec4f(0.037527006, 0.025315201, 0.292398773, 1.001186443));
    return v;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = timeline_now();
    let s = blur_strength(t);
    var lin = to_linear(textureSampleLevel(blur_x, smp, uv, 0.0).rgb);
    if (s > 1e-5) { lin = gauss(blur_x, uv, vec2f(0.0, 1.0), s * 0.21); }
    lin *= exp2(exposure_now(t));
    gpufx_write(id, vec4f(to_gamma(lin), 1.0));
}
