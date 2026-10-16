// Fisheye wipe, step 1: pick the clip, shake it with turbulent noise and pinch it through a fisheye lens.

// The animation is laid out over 0.6 s of timeline; the second clip takes over at 0.2 s.
const TIMELINE: f32 = 0.6;
const SWITCH_AT: f32 = 0.2;
const TAU: f32 = 6.2831853;

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

// Lens strength in -1..1: a pinch while the first clip rushes out, then a few small wobbles.
fn lens_bend(t: f32) -> f32 {
    var v = 0.0;
    v = key(v, t, 0.0, 0.2, 0.0, -30.0, vec4f(0.1666667, 0.1666667, 0.17, 1.0));
    v = key(v, t, 0.2, 0.3, -30.0, 0.0, vec4f(0.83, 0.0, 0.8333333, 0.8333333));
    v = key(v, t, 0.3, 0.333333, 0.0, 7.370883, LINEAR);
    v = key(v, t, 0.333333, 0.366667, 7.370883, 9.764461, LINEAR);
    v = key(v, t, 0.366667, 0.4, 9.764461, 7.994464, LINEAR);
    v = key(v, t, 0.4, 0.433333, 7.994464, 4.045226, LINEAR);
    v = key(v, t, 0.433333, 0.466667, 4.045226, 0.0, LINEAR);
    v = key(v, t, 0.466667, 0.533333, 0.0, 2.0, vec4f(0.1666667, 0.1666667, 0.77, 1.0));
    v = key(v, t, 0.533333, 0.6, 2.0, 0.0, vec4f(0.23, 0.0, 0.66, 1.0));
    return v / 100.0;
}

// Strength of the noise shake.
fn shake_size(t: f32) -> f32 {
    var v = 0.0;
    v = key(v, t, 0.033333, 0.2, 0.0, 0.03, vec4f(0.1666667, 0.1666667, 0.33, 1.0));
    v = key(v, t, 0.2, 0.3, 0.03, 0.0, vec4f(0.67, 0.0, 0.8333333, 0.8333333));
    return v;
}

// ---- Turbulent noise: gradient noise whose gradients turn as `evolve` grows ----

fn cell_seed(c: vec2f) -> f32 {
    let f = fract(c * 1324.5179);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

fn cell_pair(c: vec2f, k: f32, seed: f32) -> vec2f {
    let f = fract(c * k);
    let g = f + vec2f(dot(f, f.yx + vec2f(15.434)));
    return fract((g + g.yx + vec2f(0.523)) * g.yx + vec2f(seed));
}

const LOOP_STEPS: f32 = 300.0;

fn cell_gradient(c: vec2f, evolve: f32, layer: f32) -> vec2f {
    let seed = cell_seed(c);
    let turn = evolve * 0.25 + seed;
    let ta = floor(turn % LOOP_STEPS);
    let tb = floor((turn + 1.0) % LOOP_STEPS);
    let ka = cell_pair(c, 34.532 + ta * 2.0 + layer * 0.8031, seed);
    var kb = cell_pair(c, 34.532 + tb * 2.0 + layer * 0.8031, seed);
    kb.y += 1.0;
    let angle = mix(ka.y, kb.y, fract(turn)) * TAU;
    let grow = evolve * 2.0 + seed;
    let ga = floor(grow % LOOP_STEPS);
    let gb = floor((grow + 1.0) % LOOP_STEPS);
    let ma = cell_pair(c, 34.532 + ga * 2.0 + layer * 0.8031, seed);
    let mb = cell_pair(c, 34.532 + gb * 2.0 + layer * 0.8031, seed);
    return vec2f(cos(angle), sin(angle)) * mix(0.75, 1.0, mix(ma.x, mb.x, fract(grow)));
}

fn gradient_noise(p: vec2f, evolve: f32, layer: f32, cells: vec2f) -> f32 {
    let g = p * cells / 100.0;
    let i = floor(g);
    let f = fract(g);
    let s = smoothstep(vec2f(0.0), vec2f(1.0), f);
    let n00 = dot(cell_gradient(i, evolve, layer), f);
    let n10 = dot(cell_gradient(i + vec2f(1.0, 0.0), evolve, layer), f - vec2f(1.0, 0.0));
    let n01 = dot(cell_gradient(i + vec2f(0.0, 1.0), evolve, layer), f - vec2f(0.0, 1.0));
    let n11 = dot(cell_gradient(i + vec2f(1.0), evolve, layer), f - vec2f(1.0));
    return mix(mix(n00, n10, s.x), mix(n01, n11, s.x), s.y) * 0.5 + 0.5;
}

// Fractal sum: `detail` octaves (fractional part fades the last one in), each 1.79x finer, 0.6x weaker.
fn turbulence(p0: vec2f, detail: f32, evolve: f32, layer: f32, cells: vec2f) -> f32 {
    var p = p0;
    let whole = floor(detail);
    var total = 1.0;
    var weight = 0.6;
    var acc = gradient_noise(p, evolve, 1.0 + layer, cells);
    for (var o = 2.0; o <= 10.0; o += 1.0) {
        if (o > whole) { break; }
        p *= 100.0 / 56.0;
        total += weight;
        acc += gradient_noise(p, evolve, 1.0 + layer, cells) * weight;
        weight *= 0.6;
    }
    p *= 100.0 / 56.0;
    let part = fract(detail);
    total += weight * part;
    acc += gradient_noise(p, evolve, 1.0 + layer, cells) * weight * part;
    return clamp(acc / total, 0.0, 1.0);
}

fn mirror01(q: vec2f) -> vec2f {
    return abs(((q - 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
}

// Shake: each axis is pushed by its own noise field (noise scale 4, mirrored at the frame edge).
fn shake(uv: vec2f, size: f32, evolve: f32) -> vec2f {
    if (size <= 0.0) { return uv; }
    // The noise field is laid out with y pointing up.
    let up = vec2f(uv.x, 1.0 - uv.y);
    let cells = vec2f(720.0) * globals.size / min(globals.size.x, globals.size.y);
    let p = up / 4.0 - vec2f(10.0);
    let nx = turbulence(p, 1.0, evolve, 2.11, cells);
    let ny = turbulence(p, 1.0, evolve, 9.71, cells);
    let span = min(globals.size.x, globals.size.y);
    let push = (vec2f(nx, ny) - 0.5) * size * 10.0 * span / globals.size * 0.3;
    return mirror01(uv + push * vec2f(1.0, -1.0));
}

// ---- Fisheye lens: a mesh whose points move by sin(pi u) sin(pi v) along the ray from the centre ----

fn lens_scale(q: vec2f, bend: f32) -> f32 {
    let u = q * 0.5 + 0.5;
    let w = abs(bend) * sin(u.x * 3.1415927) * sin(u.y * 3.1415927);
    if (bend > 0.0) { return mix(1.0, 1.9, w); }
    return mix(1.0, 0.25, w);
}

// The mesh pushes a source point q to q * lens_scale(q); invert that along the ray by bisection.
fn lens(uv: vec2f, bend: f32) -> vec2f {
    if (abs(bend) < 1e-4) { return uv; }
    let p = uv * 2.0 - 1.0;
    let reach = max(abs(p.x), abs(p.y));
    if (reach < 1e-6) { return uv; }
    let edge = p / reach;
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (mid * lens_scale(edge * mid, bend) > reach) { hi = mid; } else { lo = mid; }
    }
    return edge * (0.5 * (lo + hi)) * 0.5 + 0.5;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let t = clamp(params.progress, 0.0, 1.0) * TIMELINE;
    let evolve = clamp(t / 0.3, 0.0, 1.0) * 4.0;
    let q = lens(shake(gpufx_uv(id), shake_size(t), evolve), lens_bend(t));
    var c: vec4f;
    if (t < SWITCH_AT) {
        c = textureSampleLevel(first, smp, q, 0.0);
    } else {
        c = textureSampleLevel(second, smp, q, 0.0);
    }
    gpufx_write(id, vec4f(c.rgb, 1.0));
}
