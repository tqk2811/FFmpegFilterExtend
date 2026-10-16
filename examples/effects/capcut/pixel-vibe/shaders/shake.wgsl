// Pixel Vibe, pass 3: shove and slightly zoom the frame with mirrored edges, smearing it along the shake path.

const PI: f32 = 3.14159265;
const DESIGN: f32 = 1080.0; // shake amplitudes are in pixels of a 1080 px short side
const SWING: f32 = 192.0;
const RATE: f32 = 12.0;

fn ease(u: f32) -> f32 {
    let v = clamp(u, 0.0, 1.0);
    return v * v * (3.0 - 2.0 * v);
}

// Cubic-bezier easing (handles (x1, y1), (x2, y2)), solved for x by bisection.
fn bezier(u: f32, c: vec4f) -> f32 {
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

fn strength(t: f32) -> f32 {
    if (t < 0.333333) { return bezier(clamp(t / 0.333333, 0.0, 1.0), vec4f(0.166667, 0.0, 0.833333, 1.0)); }
    return 1.0 - ease((t - 0.333333) / 0.666667);
}

fn zoom_in(t: f32) -> f32 {
    if (t < 0.333333) { return mix(1.0, 0.9, ease(t / 0.333333)); }
    return mix(0.9, 1.0, ease((t - 0.333333) / 0.666667));
}

fn smear(t: f32) -> f32 {
    if (t < 0.333333) { return 0.25; }
    return mix(0.25, 0.0, ease((t - 0.333333) / 0.666667));
}

// Camera offset in design pixels (y pointing up) at shake clock c.
fn wander(c: f32, amp: f32) -> vec2f {
    let a = PI * c * RATE;
    let x = cos(a) * 0.25 + sin(a * 1.5) * 0.16 + cos(a * 2.5) * 0.09;
    let y = sin(a) * 0.25 + cos(a * 1.5) * 0.16 + sin(a * 2.5) * 0.09;
    return vec2f(x, y) * amp * SWING;
}

fn mirror(x: vec2f) -> vec2f {
    return abs((x + 1.0) - 2.0 * floor((x + 1.0) * 0.5) - 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0);
    let short_side = min(globals.size.x, globals.size.y);
    let frame = globals.size / short_side * DESIGN; // frame size in design pixels
    let clock = params.progress * params.duration;
    let amp = strength(t);
    let scale = zoom_in(t);
    let half = smear(t) * 0.5 / 30.0;
    let o0 = wander(clock - half, amp);
    let o1 = wander(clock + half, amp);
    let p0 = (uv - 0.5) * scale + 0.5 + vec2f(o0.x, -o0.y) * scale / frame;
    let p1 = (uv - 0.5) * scale + 0.5 + vec2f(o1.x, -o1.y) * scale / frame;
    // One tap per 10 design pixels of travel, at most 8.
    let taps = clamp(ceil(length((p1 - p0) * frame) / 10.0), 1.0, 8.0);
    var sum = vec3f(0.0);
    for (var k = 0.0; k < taps; k += 1.0) {
        sum += textureSampleLevel(zoomed, smp, mirror(mix(p0, p1, k / taps)), 0.0).rgb;
    }
    gpufx_write(id, vec4f(sum / taps, 1.0));
}
