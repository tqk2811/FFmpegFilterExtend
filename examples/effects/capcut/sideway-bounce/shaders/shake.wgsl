// Sideway Bounce, pass 1: the clip under a fading light band is zoomed in, knocked sideways by a
// decaying wobble and smeared along the wobble path; the picture cuts at the midpoint.

// Size the wobble is designed for: offsets are in pixels of a frame whose short side is this long.
const DESIGN_SHORT_SIDE: f32 = 1080.0;
// Peak wobble offset (design pixels) and its angular speed factor.
const WOBBLE_REACH: f32 = 192.0;
const WOBBLE_RATE: f32 = 4.0;
// Path length (design pixels) covered by one smear sub-step, and the most sub-steps per segment.
const SMEAR_STEP: f32 = 10.0;
const SMEAR_SPLIT: i32 = 8;
// Sign of the vertical wobble in y-down coordinates.
const WOBBLE_Y_SIGN: f32 = -1.0;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        let dx = 3.0 * inv * inv * c.x + 6.0 * inv * s * (c.z - c.x) + 3.0 * s * s * (1.0 - c.z);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, c));
}

const SMOOTH: vec4f = vec4f(0.33333, 0.0, 0.66667, 1.0);
const SNAP: vec4f = vec4f(0.33333, 0.0, 0.0, 1.0);

// Rise to `peak` by the midpoint, fall back to zero.
fn hump(p: f32, peak: f32) -> f32 {
    if (p <= 0.5) { return keyed(p, 0.0, 0.5, 0.0, peak, SMOOTH); }
    return keyed(p, 0.5, 1.0, peak, 0.0, SMOOTH);
}

// Scale of the sampled area: shrinks (zooms in) toward the midpoint and back.
fn zoom_factor(p: f32) -> f32 {
    if (p <= 0.5) { return keyed(p, 0.0, 0.5, 1.0, 0.72, SNAP); }
    return keyed(p, 0.5, 1.0, 0.72, 1.0, SNAP);
}

// Wobble offset (design pixels) at clock `c`: a sum of three detuned waves per axis.
fn wobble(c: f32, reach: f32) -> vec2f {
    let a = 3.14159265 * c * WOBBLE_RATE;
    let x = cos(a) * 0.25 + sin(a * 1.5) * 0.16 + cos(a * 2.5) * 0.09;
    let y = sin(a) * 0.25 + cos(a * 1.5) * 0.16 + sin(a * 2.5) * 0.09;
    return vec2f(x, WOBBLE_Y_SIGN * y) * reach;
}

// Faint horizontal band of light rising up the frame (added on top of the clip).
fn light_band(uv: vec2f, p: f32) -> f32 {
    if (p < 0.12 || p > 0.9) { return 0.0; }
    let centre = 0.94 - 1.32 * (p - 0.333);
    var level = 0.035;
    if (p >= 0.3) { level = mix(0.075, 0.0, clamp((p - 0.333) / 0.52, 0.0, 1.0)); }
    let d = (uv.y - centre) / 0.06;
    return level * exp(-0.5 * d * d);
}

// Mirror coordinates outside [0, 1] back inside.
fn fold(v: f32) -> f32 {
    let m = v + 1.0;
    return abs(m - 2.0 * floor(m * 0.5) - 1.0);
}

fn layered(uv: vec2f, p: f32) -> vec3f {
    let q = vec2f(fold(uv.x), fold(uv.y));
    var c: vec3f;
    if (p <= 0.5) { c = textureSampleLevel(first, smp, q, 0.0).rgb; }
    else { c = textureSampleLevel(second, smp, q, 0.0).rgb; }
    return min(c + vec3f(light_band(q, p)), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    let clock = p * params.duration;
    let canvas = globals.size * (DESIGN_SHORT_SIDE / min(globals.size.x, globals.size.y));
    let px = (uv - 0.5) * canvas;
    let reach = WOBBLE_REACH * keyed(p, 0.0, 1.0, 1.0, 0.0, SMOOTH);
    let zoom = zoom_factor(p);
    let smear = hump(p, 5.0);
    let steps = max(1, i32(ceil(smear * 2.0)));
    let half_span = smear * 0.5 / 30.0;
    var sum = vec3f(0.0);
    var count = 0.0;
    var prev = (px + wobble(clock - half_span, reach)) * zoom;
    for (var k = 0; k < 16; k++) {
        if (k >= steps) { break; }
        let c1 = mix(clock - half_span, clock + half_span, f32(k + 1) / f32(steps));
        let next = (px + wobble(c1, reach)) * zoom;
        let parts = clamp(ceil(length(next - prev) / SMEAR_STEP), 1.0, f32(SMEAR_SPLIT));
        sum += layered(0.5 + prev / canvas, p);
        count += 1.0;
        for (var j = 1; j < SMEAR_SPLIT; j++) {
            if (f32(j) >= parts) { break; }
            sum += layered(0.5 + mix(prev, next, f32(j) / parts) / canvas, p);
            count += 1.0;
        }
        prev = next;
    }
    gpufx_write(id, vec4f(sum / count, 1.0));
}
