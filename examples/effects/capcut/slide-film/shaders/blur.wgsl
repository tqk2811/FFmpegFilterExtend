// Slide film, step 2: vertical blur in linear light plus a vertical streak glow on the highlights.

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

fn to_linear(c: vec3f) -> vec3f { return pow(max(c, vec3f(0.0)), vec3f(2.2)); }
fn to_gamma(c: vec3f) -> vec3f { return pow(max(c, vec3f(0.0)), vec3f(1.0 / 2.2)); }

const TAPS: i32 = 32;
// Brightness of the added streak glow per unit of strength (matched by eye).
const GLOW_GAIN: f32 = 12.0;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = timeline_now();
    let uv = gpufx_uv(id);
    var blur = key(0.0, t, 0.033333, 0.233333, 0.0, 40.0, vec4f(0.748344868, 0.123609848, 0.999, 1.0));
    blur = key(blur, t, 0.233333, 0.633333, 40.0, 0.0, vec4f(0.001, 0.0, 0.242416652, 0.816980869));
    var shine = key(0.0, t, 0.033333, 0.2, 0.0, 4.0, vec4f(0.455376091, 0.051990495, 0.867451278, 0.458409227));
    shine = key(shine, t, 0.2, 0.233333, 4.0, 7.0, vec4f(0.332640314, 0.362442674, 0.7, 1.0));
    shine = key(shine, t, 0.233333, 0.266667, 7.0, 4.0, vec4f(0.3, 0.0, 0.573763908, 0.639300261));
    shine = key(shine, t, 0.266667, 0.7, 4.0, 0.0, vec4f(0.069232987, 0.571233007, 0.51016066, 0.900794745));
    var width = key(0.08, t, 0.033333, 0.233333, 0.08, 0.25, LINEAR);
    width = key(width, t, 0.233333, 0.7, 0.25, 0.08, LINEAR);

    // Blur radius: 2.5 x strength / 1000 of the frame (matched by eye), vertical only.
    let reach = blur * 2.5 / 1000.0;
    let glow_reach = width * 0.5;
    var acc = vec3f(0.0);
    var total = 0.0;
    var glow = vec3f(0.0);
    var glow_total = 0.0;
    for (var i = -TAPS; i <= TAPS; i++) {
        let x = f32(i) / f32(TAPS);
        let w = exp(-0.5 * (x * 2.5) * (x * 2.5));
        let a = textureSampleLevel(layered, smp, clamp(uv + vec2f(0.0, reach * x), vec2f(0.0), vec2f(1.0)), 0.0).rgb;
        acc += to_linear(a) * w;
        total += w;
        if (shine > 0.0) {
            // Highlights above 0.5 smeared vertically, red reaching a little further than blue.
            let g = textureSampleLevel(layered, smp, clamp(uv + vec2f(0.0, glow_reach * x), vec2f(0.0), vec2f(1.0)), 0.0).rgb;
            let wg = exp(-5.0 * abs(x));
            glow += max(g - vec3f(0.5), vec3f(0.0)) * vec3f(1.1, 1.0, 0.9) * wg;
            glow_total += wg;
        }
    }
    var lin = acc / total;
    if (shine > 0.0) { lin += to_linear(glow / glow_total) * shine * GLOW_GAIN; }
    gpufx_write(id, vec4f(to_gamma(lin), 1.0));
}
