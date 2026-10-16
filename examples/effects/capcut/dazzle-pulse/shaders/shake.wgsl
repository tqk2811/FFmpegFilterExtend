// Dazzle Pulse, pass 3: jitter and punch-zoom the frame with a two-tap motion blur, then split red and blue apart.

const SPAN: f32 = 0.7;
const MID: f32 = 0.333333;
const FRAME: f32 = 0.033333; // the "previous frame" the motion blur smears from
const SHAKE_START: f32 = 0.133333;
const SPLIT: f32 = 0.06;     // colour split at the peak

// Camera jitter positions, one every FRAME seconds from SHAKE_START (y pointing up).
const SHAKE = array<vec2f, 14>(
    vec2f(0.5, 0.5), vec2f(0.5, 0.5), vec2f(0.507374, 0.492568), vec2f(0.518567, 0.480934),
    vec2f(0.517911, 0.500513), vec2f(0.477900, 0.506011), vec2f(0.437015, 0.470490), vec2f(0.482906, 0.461104),
    vec2f(0.515660, 0.461622), vec2f(0.495010, 0.462446), vec2f(0.491725, 0.483974), vec2f(0.505293, 0.499549),
    vec2f(0.5, 0.5), vec2f(0.5, 0.5));

// Cubic-bezier easing (control points (x1, y1), (x2, y2)), solved for x by bisection.
fn ease(u: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let m = 0.5 * (lo + hi);
        let r = 1.0 - m;
        let x = 3.0 * r * r * m * c.x + 3.0 * r * m * m * c.z + m * m * m;
        if (x > u) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * c.y + 3.0 * r * s * s * c.w + s * s * s;
}

// One animated value: v0 before t0, v1 after t1, eased in between.
fn key(t: f32, t0: f32, t1: f32, v0: f32, v1: f32, c: vec4f) -> f32 {
    if (t <= t0) { return v0; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease((t - t0) / (t1 - t0), c));
}

// Rise from 0 to a peak at t1 and fall back to 0 at t2, each half with its own easing.
fn pulse(t: f32, t0: f32, t1: f32, t2: f32, peak: f32, up: vec4f, down: vec4f) -> f32 {
    if (t < t1) { return key(t, t0, t1, 0.0, peak, up); }
    return key(t, t1, t2, peak, 0.0, down);
}

fn grain(a: f32, b: f32) -> f32 {
    var f = fract(vec2f(a, b) * 13.517);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y);
}

fn shake_at(t: f32) -> vec2f {
    let k = (t - SHAKE_START) / FRAME;
    if (k <= 0.0 || k >= 13.0) { return vec2f(0.0); }
    let i = u32(floor(k));
    var table = SHAKE;
    return mix(table[i], table[i + 1u], fract(k)) - vec2f(0.5);
}

fn zoom_at(t: f32) -> f32 {
    return 1.0 + pulse(t, 0.166667, MID, 0.5, 0.2, vec4f(0.166667, 0.166667, 0.5, 1.0), vec4f(0.5, 0.0, 0.833333, 0.833333));
}

// Where the layer is sampled for one blend weight w between the previous (0) and current (1) frame.
fn placed(p: vec2f, prev_off: vec2f, cur_off: vec2f, prev_zoom: f32, cur_zoom: f32, w: f32) -> vec2f {
    let offset = mix(prev_off, cur_off, w);
    let scale = mix(prev_zoom, cur_zoom, w);
    return (p - offset - vec2f(0.5)) / scale + vec2f(0.5);
}

fn layer(s: vec2f) -> vec3f {
    if (any(s < vec2f(0.0)) || any(s > vec2f(1.0))) { return vec3f(0.0); }
    return textureSampleLevel(warped, smp, vec2f(s.x, 1.0 - s.y), 0.0).rgb;
}

// Two-tap motion blur along the path of six transforms (blend weights 0.75..1.25).
fn blurred(p: vec2f, t: f32) -> vec3f {
    let po = shake_at(t - FRAME);
    let co = shake_at(t);
    let pz = zoom_at(t - FRAME);
    let cz = zoom_at(t);
    var pts: array<vec2f, 6>;
    for (var i = 0; i < 6; i++) { pts[i] = placed(p, po, co, pz, cz, 0.75 + 0.1 * f32(i)); }
    var sum = vec3f(0.0);
    for (var j = 0; j < 2; j++) {
        let k = f32(j);
        let u = clamp(k + (grain(k + p.x, k * p.y) - 0.5) * 0.5, 0.0, 1.0);
        let seg = clamp(floor(u * 5.0), 0.0, 4.0);
        let n = u32(seg);
        sum += layer(mix(pts[n], pts[n + 1u], u * 5.0 - seg));
    }
    return sum * 0.5;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let p = vec2f(uv.x, 1.0 - uv.y);
    let amt = pulse(t, 0.133333, MID, 0.533333, 1.0, vec4f(0.166667, 0.166667, 0.5, 1.0), vec4f(0.5, 0.0, 0.833333, 0.833333));
    let split = vec2f(SPLIT, -SPLIT) * amt * (vec2f(1.0) - p) * p;
    let g = blurred(p, t).g;
    let r = blurred(p + split, t).r;
    let b = blurred(p - split, t).b;
    gpufx_write(id, vec4f(r, g, b, 1.0));
}
