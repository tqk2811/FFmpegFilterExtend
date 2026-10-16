// The first clip shrinks away onto a spinning cube that splits into two halves, a cube of the second clip grows and spins between them, then the camera rushes back in onto the second clip.

// The animation runs over this many seconds of comp time for progress 0..1.
const SPAN: f32 = 2.0;
// Depth push of the whole picture per unit of keyed depth (as a fraction of the camera distance).
const DEPTH_GAIN: f32 = 0.72;
// Sub-frames averaged for the camera motion blur.
const BLUR_TAPS: i32 = 12;
// Fraction of a frame (1/30 s) covered by the blur, and where it is centred.
const SHUTTER: f32 = 0.87;
const SHUTTER_CENTRE: f32 = -0.25;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var s = x;
    for (var i = 0; i < 10; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        let dx = 3.0 * inv * inv * c.x + 6.0 * inv * s * (c.z - c.x) + 3.0 * s * s * (1.0 - c.z);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Value animated from `a` to `b` between times t0 and t1 with the given easing curve.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, curve: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, curve));
}

const SMOOTH: vec4f = vec4f(0.33333, 0.0, 0.66667, 1.0);

// Spin (degrees) of the two halves of the first clip's cube; `stop` is when the second, slow turn would end.
fn half_spin(t: f32, stop: f32) -> f32 {
    if (t < 0.366667) { return keyed(t, 0.066667, 0.366667, 0.0, -180.0, SMOOTH); }
    if (t < 0.5) { return -180.0; }
    return keyed(t, 0.5, stop, -180.0, 180.0, vec4f(0.33333, 0.0, 0.83333, 1.0));
}

// Camera push (depth) and roll (degrees) of the whole picture at comp time t.
fn camera(t: f32) -> vec2f {
    let ease = vec4f(0.166667, 0.0, 0.666667, 1.0);
    var depth = 0.0;
    if (t < 0.366667) {
        depth = keyed(t, 0.033333, 0.366667, 0.0, 2.1875, ease);
    } else if (t < 1.0) {
        depth = keyed(t, 0.366667, 1.0, 2.1875, 0.0, ease);
    } else {
        depth = keyed(t, 1.566667, 1.8, 0.0, -0.3390625, ease);
    }
    var roll = 0.0;
    if (t < 1.3) { roll = keyed(t, 0.733333, 1.3, 0.0, 17.0, SMOOTH); }
    else { roll = keyed(t, 1.3, 1.8, 17.0, 0.0, SMOOTH); }
    return vec2f(depth, roll);
}

// A 2x2x2 cube 6 units in front of a 60 degree camera, spun `spin` degrees about the vertical
// axis, every side showing the clip. `p` is in picture heights from the centre, y down.
// Returns colour + coverage.
fn cube_at(p: vec2f, spin: f32, use_second: bool) -> vec4f {
    let k = 2.0 * tan(radians(30.0));
    let a = radians(spin);
    let c = cos(a);
    let s = sin(a);
    let dir_w = vec3f(p.x * k, -p.y * k, -1.0);
    // Ray into the cube's own frame (centre at the origin).
    let org = vec3f(-6.0 * s, 0.0, 6.0 * c);
    let dir = vec3f(dir_w.x * c - dir_w.z * s, dir_w.y, dir_w.x * s + dir_w.z * c);
    // Keep axis-parallel rays off an exact zero so the slab test never divides by it.
    let inv = 1.0 / select(dir, vec3f(1e-6), abs(dir) < vec3f(1e-6));
    let t0 = (vec3f(-1.0) - org) * inv;
    let t1 = (vec3f(1.0) - org) * inv;
    let tmin = min(t0, t1);
    let tmax = max(t0, t1);
    let near = max(max(tmin.x, tmin.y), tmin.z);
    let far = min(min(tmax.x, tmax.y), tmax.z);
    if (near > far || far <= 0.0) { return vec4f(0.0); }
    let h = org + dir * near;
    var fc: vec2f;
    if (near == tmin.z) {
        fc = vec2f(select(1.0 - h.x, h.x + 1.0, h.z > 0.0) * 0.5, (1.0 - h.y) * 0.5);
    } else if (near == tmin.x) {
        fc = vec2f(select(1.0 + h.z, 1.0 - h.z, h.x > 0.0) * 0.5, (1.0 - h.y) * 0.5);
    } else {
        fc = vec2f((h.x + 1.0) * 0.5, (h.z + 1.0) * 0.5);
    }
    fc = clamp(fc, vec2f(0.0), vec2f(1.0));
    var col: vec3f;
    if (use_second) { col = textureSampleLevel(second, smp, fc, 0.0).rgb; }
    else { col = textureSampleLevel(first, smp, fc, 0.0).rgb; }
    return vec4f(col, 1.0);
}

// The layered picture (before the camera move) at point q, in picture heights from the centre.
fn scene(q: vec2f, t: f32) -> vec3f {
    var out = vec3f(0.0);
    let slide = keyed(t, 0.466667, 1.133333, 0.0, 218.0 / 1280.0, SMOOTH);
    let fade = 1.0 - 0.01 * keyed(t, 1.533333, 1.833333, 0.0, 100.0, SMOOTH);
    // Lower half of the first clip's cube, moved down and grown 1.5x.
    let lower_local = (q - vec2f(0.0, 220.0 / 218.0 * slide)) / 1.5;
    if (lower_local.y > -0.01) {
        let c = cube_at(lower_local, half_spin(t, 2.666667), false);
        out = mix(out, c.rgb, c.a * fade);
    }
    // The second clip's cube growing in the middle.
    if (t >= 0.7) {
        var grow = 0.0;
        if (t < 1.133333) { grow = keyed(t, 0.466667, 1.133333, 0.0, 0.89, SMOOTH); }
        else if (t < 1.533333) { grow = 0.89; }
        else { grow = keyed(t, 1.533333, 2.366667, 0.89, 1.0, vec4f(0.166667, 0.0, 0.833333, 1.0)); }
        if (grow > 1e-4) {
            let c = cube_at(q / grow, keyed(t, 0.7, 1.766667, 0.0, 180.0, SMOOTH), true);
            out = mix(out, c.rgb, c.a);
        }
    }
    // Upper half of the first clip's cube, moved up and grown 1.5x.
    let upper_local = (q + vec2f(0.0, slide)) / 1.5;
    if (upper_local.y < 0.01) {
        let c = cube_at(upper_local, half_spin(t, 3.233333), false);
        out = mix(out, c.rgb, c.a * fade);
    }
    return out;
}

// Picture seen through the camera at comp time t: pushed back in depth and rolled.
fn through_camera(o: vec2f, t: f32) -> vec3f {
    let cam = camera(t);
    let scale = 1.0 / (1.0 + DEPTH_GAIN * cam.x);
    let r = radians(cam.y);
    let p = o / scale;
    let q = vec2f(p.x * cos(r) + p.y * sin(r), -p.x * sin(r) + p.y * cos(r));
    return scene(q, t);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SPAN;
    if (t < 0.033333) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    let plain_b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    if (t >= 1.8) { gpufx_write(id, vec4f(plain_b, 1.0)); return; }

    let ratio = globals.size.x * globals.pixel_aspect / globals.size.y;
    let o = vec2f((uv.x - 0.5) * ratio, uv.y - 0.5);
    // Camera motion blur: average the picture over part of the last frame interval.
    var acc = vec3f(0.0);
    for (var k = 0; k < BLUR_TAPS; k++) {
        let f = SHUTTER_CENTRE + SHUTTER * (f32(k) / f32(BLUR_TAPS - 1) - 0.5);
        acc += through_camera(o, t + f / 30.0);
    }
    var col = acc / f32(BLUR_TAPS);
    // The plain second clip fades in on top at the end.
    let cover = 0.01 * keyed(t, 1.666667, 1.8, 0.0, 100.0, vec4f(0.166667, 0.166667, 0.833333, 0.833333));
    col = mix(col, plain_b, cover);
    gpufx_write(id, vec4f(col, 1.0));
}
