// Pixel Vibe, pass 1: pick the clip for the current half, multiply a drifting halftone dot screen over it and push the exposure.

const SHEET: vec2f = vec2f(1280.0, 720.0); // the dot sheet, in its own pixels
const PITCH: f32 = 12.2;                   // dot spacing on the sheet
const TILT: f32 = 0.5236;                  // dot grid angle (30 degrees)

fn ease(u: f32) -> f32 {
    let v = clamp(u, 0.0, 1.0);
    return v * v * (3.0 - 2.0 * v);
}

fn cell_hash(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

fn smooth_noise(p: vec2f) -> f32 {
    let c = floor(p);
    let f = p - c;
    let w = f * f * (3.0 - 2.0 * f);
    let a = cell_hash(c);
    let b = cell_hash(c + vec2f(1.0, 0.0));
    let d = cell_hash(c + vec2f(0.0, 1.0));
    let e = cell_hash(c + vec2f(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(d, e, w.x), w.y);
}

// Ink coverage of the screen: broad soft patches, mostly light.
fn ink(p: vec2f) -> f32 {
    let n = smooth_noise(p / 380.0 + vec2f(3.7, 1.3)) * 0.7 + smooth_noise(p / 170.0 + vec2f(8.1, 5.9)) * 0.3;
    return clamp(0.04 + 0.62 * pow(1.0 - n, 1.6), 0.0, 1.0);
}

// Brightness of the dot sheet at sheet pixel p (black dots on white).
fn dots(p: vec2f) -> f32 {
    let cs = cos(TILT);
    let sn = sin(TILT);
    let g = vec2f(cs * p.x + sn * p.y, -sn * p.x + cs * p.y) / PITCH;
    let centre = floor(g) + 0.5;
    let dark = ink(p);
    let radius = sqrt(dark / 3.14159265);
    let dist = length(g - centre);
    let aa = 1.0 / PITCH;
    return smoothstep(radius - aa, radius + aa, dist);
}

// The sheet with its red and blue pulled apart towards / away from the middle.
fn sheet(s: vec2f) -> vec3f {
    let off = vec2f(0.2) * (vec2f(1.0) - s) * s;
    return vec3f(dots((s + off) * SHEET), dots(s * SHEET), dots((s - off) * SHEET));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    var c = textureSampleLevel(first, smp, uv, 0.0).rgb;
    if (t > 0.5) { c = textureSampleLevel(second, smp, uv, 0.0).rgb; }

    // The sheet covers the frame by its short side, grows 130 -> 140 % and turns 8 degrees.
    let short_side = min(globals.size.x, globals.size.y);
    let k = ease(t);
    let grow = mix(1.3, 1.4, k);
    let turn = radians(8.0 * k);
    let px = (uv - 0.5) * globals.size / short_side * SHEET.y; // sheet pixels from the centre
    let cs = cos(turn);
    let sn = sin(turn);
    let local = vec2f(cs * px.x + sn * px.y, -sn * px.x + cs * px.y) / grow;
    let s = local / SHEET + 0.5;
    let fade = select(ease((1.0 - t) * 2.0), ease(t * 2.0), t < 0.5);
    var screen = vec3f(1.0);
    if (all(s >= vec2f(0.0)) && all(s <= vec2f(1.0))) { screen = sheet(s); }
    c *= mix(vec3f(1.0), screen, fade);

    // Exposure flash in linear light (gamma 2.2), peaking at a third.
    var stops = 3.0 * ease(t / 0.333333);
    if (t > 0.333333) { stops = 3.0 * (1.0 - ease((t - 0.333333) / 0.666667)); }
    let lin = pow(max(c, vec3f(0.0)), vec3f(2.2)) * exp2(stops);
    c = clamp(pow(lin, vec3f(1.0 / 2.2)), vec3f(0.0), vec3f(1.0));
    gpufx_write(id, vec4f(c, 1.0));
}
