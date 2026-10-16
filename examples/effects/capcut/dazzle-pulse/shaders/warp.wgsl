// Dazzle Pulse, pass 2: bulge the middle of the frame, ripple it with drifting gradient noise and push the exposure.
//
// Worked out with y pointing up (0 at the bottom of the frame).

const SPAN: f32 = 0.7;
const MID: f32 = 0.333333;
const BULGE_RADIUS: vec2f = vec2f(1.38, 1.59);
const TAPER: f32 = 0.35;
const NOISE_SCALE: f32 = 4.0;
const CYCLE: f32 = 300.0;
const GAMMA: f32 = 2.2;
const TAU: f32 = 6.2831853;
const REACH: f32 = 0.3;      // share of the displacement strength that reaches the picture (fitted to the demo)

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

fn cell_seed(c: vec2f) -> f32 {
    var f = fract(c * 1324.5179);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y);
}

fn cell_pair(c: vec2f, phase: f32, lane: f32, seed: f32) -> vec2f {
    var f = fract(c * (34.532 + phase * 2.0 + lane * 0.8031));
    f += dot(f, f.yx + 15.434);
    return fract((f + f.yx + 0.523) * f.yx + seed);
}

fn wrap_cycle(v: f32) -> f32 {
    return floor(v - CYCLE * floor(v / CYCLE));
}

// Gradient of one lattice point; its angle and length drift with the evolution clock.
fn lattice(c: vec2f, evo: f32, lane: f32) -> vec2f {
    let seed = cell_seed(c);
    let a = evo * 0.25 + seed;
    let a0 = cell_pair(c, wrap_cycle(a), lane, seed);
    let a1 = cell_pair(c, wrap_cycle(a + 1.0), lane, seed);
    let angle = mix(a0.y, a1.y + 1.0, fract(a)) * TAU;
    let b = evo * 2.0 + seed;
    let b0 = cell_pair(c, wrap_cycle(b), lane, seed);
    let b1 = cell_pair(c, wrap_cycle(b + 1.0), lane, seed);
    return vec2f(cos(angle), sin(angle)) * mix(0.75, 1.0, mix(b0.x, b1.x, fract(b)));
}

fn gradient_noise(q: vec2f, evo: f32, lane: f32) -> f32 {
    let span = vec2f(720.0) * globals.size / min(globals.size.x, globals.size.y);
    let g = q * span / 100.0;
    let c = floor(g);
    let f = fract(g);
    let s = smoothstep(vec2f(0.0), vec2f(1.0), f);
    let n00 = dot(lattice(c, evo, lane), f);
    let n10 = dot(lattice(c + vec2f(1.0, 0.0), evo, lane), f - vec2f(1.0, 0.0));
    let n01 = dot(lattice(c + vec2f(0.0, 1.0), evo, lane), f - vec2f(0.0, 1.0));
    let n11 = dot(lattice(c + vec2f(1.0), evo, lane), f - vec2f(1.0));
    return clamp(mix(mix(n00, n10, s.x), mix(n01, n11, s.x), s.y) * 0.5 + 0.5, 0.0, 1.0);
}

fn mirror(p: vec2f) -> vec2f {
    let m = p - vec2f(1.0);
    return abs(m - 2.0 * floor(m / 2.0) - vec2f(1.0));
}

fn brighten(c: f32, stops: f32) -> f32 {
    return clamp(pow(pow(max(c, 0.0), GAMMA) * exp2(stops), 1.0 / GAMMA), 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let p = vec2f(uv.x, 1.0 - uv.y);

    // Bulge: push pixels outward from a centre that rises and falls with the swell.
    let ease_io = vec4f(0.43, 0.0, 0.57, 1.0);
    let height = pulse(t, 0.033333, MID, 0.6, 0.25, ease_io, ease_io);
    let d = p - vec2f(0.5);
    let r = clamp(1.0 - length((d + vec2f(0.0, height)) * 2.0 / BULGE_RADIUS), 0.0, 1.0);
    let lift = sqrt(0.001 + smoothstep(TAPER * TAPER - 0.001, sqrt(TAPER) + 0.001, r) * r);
    let b = d + d * (2.0 - length(d)) * (-height * lift) + vec2f(0.5);

    // Turbulent displacement of the bulged position.
    let size = pulse(t, 0.0, MID, 0.666667, 0.02, ease_io, ease_io);
    let evo = key(t, 0.0, 0.666667, 0.0, 540.0, vec4f(0.31, 0.0, 0.69, 1.0)) / 90.0;
    let q = b / NOISE_SCALE - vec2f(10.0);
    let n = vec2f(gradient_noise(q, evo, 3.11), gradient_noise(q, evo, 10.71));
    let shift = (n - vec2f(0.5)) * size * 10.0 * REACH * min(globals.size.x, globals.size.y) / globals.size;
    let s = mirror(b + shift);

    var color = textureSampleLevel(zoomed, smp, vec2f(s.x, 1.0 - s.y), 0.0).rgb;
    let stops = pulse(t, 0.0, MID, 0.666667, 2.0, vec4f(0.29, 0.0, 0.833333, 0.833333), vec4f(0.166667, 0.166667, 0.71, 1.0));
    color = vec3f(brighten(color.r, stops), brighten(color.g, stops), brighten(color.b, stops));
    gpufx_write(id, vec4f(color, 1.0));
}
