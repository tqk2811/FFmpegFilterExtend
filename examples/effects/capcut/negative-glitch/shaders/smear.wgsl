// Negative Glitch, pass 2: shake and zoom the graded frame (mirrored edges), then smear it sideways like a weak analogue signal.

const SPAN: f32 = 2.0;
const PI: f32 = 3.14159265;
const DESIGN: f32 = 1080.0; // shake amplitudes are in pixels of a 1080 px short side
const STEP: f32 = 1.0 / 720.0; // smear taps, in units of the short side

fn ramp(t: f32, t0: f32, t1: f32, v0: f32, v1: f32) -> f32 {
    let u = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(v0, v1, u * u * (3.0 - 2.0 * u));
}

fn speed_gain(t: f32) -> f32 {
    if (t < 1.00166) { return ramp(t, 0.952507, 1.00166, 0.1, 3.5); }
    return ramp(t, 1.00166, 1.050846, 3.5, 0.1);
}

fn zoom_out(t: f32) -> f32 {
    if (t < 1.05599) { return ramp(t, 0.947852, 1.05599, 1.0, 1.3); }
    return ramp(t, 1.05599, 1.16416, 1.3, 1.0);
}

// Vertical camera wobble in design pixels: one steady sine plus a three-tone wander.
fn wobble(clock: f32, gain: f32) -> f32 {
    let steady = sin(PI * clock * gain * 0.5) * 80.0;
    let a = PI * clock * gain * 6.7;
    let wander = sin(a) * 0.25 + cos(a * 1.5) * 0.16 + sin(a * 2.5) * 0.09;
    return steady + wander * 192.0;
}

fn mirror(x: vec2f) -> vec2f {
    return abs((x + 1.0) - 2.0 * floor((x + 1.0) * 0.5) - 1.0);
}

fn shaken(uv: vec2f, origin: vec2f, scale: f32) -> vec3f {
    let s = mirror((uv - 0.5) * scale + 0.5 + origin);
    return textureSampleLevel(graded, smp, s, 0.0).rgb;
}

fn to_ycc(c: vec3f) -> vec3f {
    let y = dot(c, vec3f(0.299, 0.587, 0.114));
    return vec3f(y, (c.b - y) * 0.565, (c.r - y) * 0.713);
}

fn from_ycc(v: vec3f) -> vec3f {
    return vec3f(v.x + 1.403 * v.z, v.x - 0.344 * v.y - 0.714 * v.z, v.x + 1.77 * v.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let short_side = min(globals.size.x, globals.size.y);
    let frame = globals.size / short_side; // frame size in short-side units
    // With `animate` off the shake clock stays at 0, as in CapCut's export.
    let clock = select(0.0, params.progress * params.duration, params.animate != 0u);
    let scale = zoom_out(t);
    let origin = vec2f(0.0, -wobble(clock, speed_gain(t)) / DESIGN) * scale / frame;
    let dx = vec2f(STEP / frame.x, 0.0);

    let here = shaken(uv, origin, scale);
    var sum = here;
    for (var i = 1; i <= 8; i++) { sum += shaken(uv - dx * f32(i), origin, scale); }
    let sharp = clamp(here + (here - sum / 9.0) * 0.6, vec3f(0.0), vec3f(1.0));
    var ycc = to_ycc(sharp);
    let trail = to_ycc(shaken(uv - dx * 8.0, origin, scale));
    ycc = vec3f(ycc.x, mix(ycc.yz, trail.yz, vec2f(0.6)));
    let soft = clamp(from_ycc(ycc), vec3f(0.0), vec3f(1.0));
    gpufx_write(id, vec4f(mix(here, soft, 0.8), 1.0));
}
