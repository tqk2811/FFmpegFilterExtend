// Subject flash, step 5: horizontal gaussian pre-blur.

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

fn bokeh_samples(t: f32) -> f32 {
    if (t < SWITCH_AT) { return ramp(t, 1.1, 1.266667, 0.0, 70.1); }
    return ramp(t, 1.6, 1.766667, 70.1, 0.0);
}

// Blur strength curve shared by the pre-blur and the bokeh.
fn blur_level(t: f32) -> f32 { return pow(bokeh_samples(t) / 79.0, 0.35); }

fn bell(x: f32) -> f32 { return 0.39894 * exp(-0.5 * x * x / 16.0) / 4.0; }

// Unit step of the soft pre-blur: one pixel of a 720 px short side.
fn soft_unit() -> vec2f {
    return vec2f(1.0) / (globals.size / min(globals.size.x, globals.size.y) * 720.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let taps = 22.0 * blur_level(timeline_now()) * 0.7;
    var acc = textureSampleLevel(soft_y, smp, uv, 0.0).rgb * bell(0.0);
    var total = bell(0.0);
    let stride = vec2f(soft_unit().x, 0.0);
    for (var i = 1.0; i <= taps; i += 1.0) {
        let w = bell(i / taps * 15.0);
        let pair = textureSampleLevel(soft_y, smp, uv + stride * i, 0.0).rgb + textureSampleLevel(soft_y, smp, uv - stride * i, 0.0).rgb;
        acc += pair * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(acc / total, 1.0));
}
