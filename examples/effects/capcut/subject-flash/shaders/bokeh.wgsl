// Subject flash, step 6: bright round bokeh on a reduced grid kept in the top-left corner.

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

const FLARE: f32 = 539.45;

fn bokeh_grid(level: f32) -> vec2f {
    return max(floor(globals.size * mix(1.0, 0.4, level)), vec2f(1.0));
}

fn flare_weight(c: vec4f) -> vec4f { return pow(c, vec4f(9.0)) * FLARE + vec4f(0.4); }

// A filled disc of taps plus a ring, weighted hard toward bright taps.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = timeline_now();
    let level = blur_level(t);
    let grid = bokeh_grid(level);
    if (f32(id.x) >= grid.x || f32(id.y) >= grid.y) { gpufx_write(id, vec4f(0.0)); return; }
    let uv = (vec2f(id.xy) + vec2f(0.5)) / grid;
    if (level < 0.01) {
        gpufx_write(id, textureSampleLevel(soft, smp, uv, 0.0));
        return;
    }
    let screen = globals.size / min(globals.size.x, globals.size.y) * 720.0;
    let size = 7.5 * bokeh_samples(t) / 79.0 * 0.7;
    let unit = vec2f(2.0 * size) / screen;
    let stride = mix(2.0, 0.5, level);
    // Tap counts are capped (about 180 disc + 48 ring fetches) to keep the pass affordable.
    let reach = clamp(12.0 / stride, 5.0, 14.0);
    var brightest = vec4f(0.0);
    var sum = vec4f(0.0);
    var weight = vec4f(0.4);
    if (level >= 0.3) {
        for (var i = 0.0; i < 30.0; i += 1.0) {
            if (i > reach) { break; }
            for (var j = 0.0; j < 30.0; j += 1.0) {
                if (j > reach) { break; }
                let o = vec2f(mix(-11.0, 11.0, i / reach), mix(-11.0, 11.0, j / reach));
                if (dot(o, o) > 121.0) { continue; }
                let c = textureSampleLevel(soft, smp, uv - 0.5 * o * unit, 0.0);
                brightest = max(brightest, c * 0.85);
                let w = flare_weight(c) * 0.5;
                sum += w * c;
                weight += w;
            }
        }
    }
    let ring = clamp(34.0 / stride, 15.0, 48.0);
    let turn = 6.28 / ring;
    var o = vec2f(11.0, 0.0);
    for (var i = 0.0; i < 70.0; i += 1.0) {
        if (i > ring) { break; }
        o = vec2f(o.x * cos(turn) + o.y * sin(turn), -o.x * sin(turn) + o.y * cos(turn));
        let c = textureSampleLevel(soft, smp, uv - 0.5 * o * unit, 0.0);
        brightest = max(brightest, c);
        let w = flare_weight(c);
        sum += w * c;
        weight += w;
    }
    let res = clamp(sum / weight, vec4f(0.0), vec4f(1.0));
    gpufx_write(id, vec4f(mix(res, brightest, res).rgb, 1.0));
}
