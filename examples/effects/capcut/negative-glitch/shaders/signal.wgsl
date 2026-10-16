// Negative Glitch, pass 3: sharpen the smeared signal, add blotchy colour noise and drain the colour row by row.

const SPAN: f32 = 2.0;
const STEP: f32 = 1.0 / 720.0;

fn ramp(t: f32, t0: f32, t1: f32, v0: f32, v1: f32) -> f32 {
    let u = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(v0, v1, u * u * (3.0 - 2.0 * u));
}

fn blotches(t: f32) -> f32 {
    if (t < 1.1) { return ramp(t, 0.883757, 0.93776, 0.0, 0.17); }
    return ramp(t, 1.1, 1.208203, 0.17, 0.0);
}

fn fading(t: f32) -> f32 {
    if (t < 1.1) { return ramp(t, 0.883757, 0.93776, 0.0, 1.0); }
    return ramp(t, 1.1, 1.208203, 1.0, 0.01);
}

// Smoothstep that also accepts equal or reversed edges.
fn edge(e0: f32, e1: f32, x: f32) -> f32 {
    var u: f32;
    if (e0 == e1) { u = select(0.0, 1.0, x >= e1); } else { u = clamp((x - e0) / (e1 - e0), 0.0, 1.0); }
    return u * u * (3.0 - 2.0 * u);
}

fn hash(p: vec2f) -> f32 {
    var f = fract(p * 1324.5179);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y);
}

fn lattice_dir(cell: vec2f, seed: f32) -> vec2f {
    var a = fract(cell * (34.532 + seed * 0.3973));
    a += dot(a, a.yx + 15.434);
    let b = a.yx;
    return fract((a + b + 0.523) * b + hash(cell)) * 2.0 - 1.0;
}

// Gradient noise on a 100 px grid (720 px short side), 0..1.
fn blob(p: vec2f, seed: f32, frame: vec2f) -> f32 {
    let q = p * 720.0 * frame / 100.0;
    let c = floor(q);
    let f = q - c;
    let w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let n00 = dot(lattice_dir(c, seed), f);
    let n10 = dot(lattice_dir(c + vec2f(1.0, 0.0), seed), f - vec2f(1.0, 0.0));
    let n01 = dot(lattice_dir(c + vec2f(0.0, 1.0), seed), f - vec2f(0.0, 1.0));
    let n11 = dot(lattice_dir(c + vec2f(1.0), seed), f - vec2f(1.0));
    return mix(mix(n00, n10, w.x), mix(n01, n11, w.x), w.y) * 0.5 + 0.5;
}

fn to_hsl(c: vec3f) -> vec3f {
    let lo = min(min(c.r, c.g), c.b);
    let hi = max(max(c.r, c.g), c.b);
    let span = hi - lo;
    var o = vec3f(0.0, 0.0, (hi + lo) * 0.5);
    if (span != 0.0) {
        if (o.z < 0.5) { o.y = span / (hi + lo); } else { o.y = span / (2.0 - hi - lo); }
        let d = ((vec3f(hi) - c) / 6.0 + span * 0.5) / span;
        if (c.r == hi) { o.x = d.b - d.g; }
        else if (c.g == hi) { o.x = 1.0 / 3.0 + d.r - d.b; }
        else { o.x = 2.0 / 3.0 + d.g - d.r; }
        o.x = fract(o.x);
    }
    return o;
}

fn from_hsl(h: vec3f) -> vec3f {
    if (h.y == 0.0) { return vec3f(h.z); }
    var top: f32;
    if (h.z < 0.5) { top = h.z * (1.0 + h.y); } else { top = h.z + h.y - h.y * h.z; }
    let bottom = 2.0 * h.z - top;
    let k = fract(h.x) * 6.0;
    let hue = clamp(vec3f(abs(k - 3.0) - 1.0, 2.0 - abs(k - 2.0), 2.0 - abs(k - 4.0)), vec3f(0.0), vec3f(1.0));
    return vec3f(bottom) + hue * (top - bottom);
}

fn to_ycc(c: vec3f) -> vec3f {
    let y = dot(c, vec3f(0.299, 0.587, 0.114));
    return vec3f(y, (c.b - y) * 0.565, (c.r - y) * 0.713);
}

fn from_ycc(v: vec3f) -> vec3f {
    return vec3f(v.x + 1.403 * v.z, v.x - 0.344 * v.y - 0.714 * v.z, v.x + 1.77 * v.y);
}

fn overlay(a: f32, b: f32) -> f32 {
    if (a < 0.5) { return 2.0 * a * b; }
    return 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let frame = globals.size / min(globals.size.x, globals.size.y);
    let dx = vec2f(STEP / frame.x, 0.0);

    // Light luma sharpen against a 6-tap trailing average.
    let here = textureSampleLevel(smeared, smp, uv, 0.0).rgb;
    var sum = here;
    for (var i = 1; i <= 5; i++) { sum += textureSampleLevel(smeared, smp, uv - dx * f32(i), 0.0).rgb; }
    let now = to_ycc(here);
    let avg = to_ycc(sum / 6.0);
    let sharp = vec3f(now.x + (now.x - avg.x) * 0.4, mix(now.yz, avg.yz, vec2f(0.05)));
    var c = clamp(from_ycc(sharp), vec3f(0.0), vec3f(1.0));

    let amount = blotches(t);
    let loss = fading(t);
    let seed = amount + loss;
    let gv = vec2f(uv.x, 1.0 - uv.y); // noise space has y pointing up

    // Colour blotches from three offset noise fields.
    let luma = dot(c, vec3f(0.299, 0.587, 0.114));
    let np = gv * vec2f(2.3255813, 112.35955) - 10.0;
    var n = vec3f(blob(np, seed, frame), blob(np - vec2f(1.01, 0.137), seed, frame), blob(np - vec2f(1.73, 0.659), seed, frame));
    n.x *= 0.92 + luma * 0.05 + amount * 0.05;
    n.y *= 0.85 + luma * 0.18 + amount * 0.05;
    var nh = to_hsl(clamp(n, vec3f(0.0), vec3f(1.0)));
    nh.y = min(1.0, nh.y * (1.0 + amount * 10.0));
    let tint = clamp(from_hsl(nh), vec3f(0.0), vec3f(1.0));
    c = mix(c, tint, amount * 0.5);
    let ov = vec3f(overlay(c.r, tint.r), overlay(c.g, tint.g), overlay(c.b, tint.b));
    let lift = max(vec3f(1.0) - (vec3f(1.0) - tint) / 0.5, vec3f(0.0));
    let dark = edge(0.5882353, 0.5098039, dot(c, vec3f(0.299, 0.587, 0.114)));
    let blended = mix(ov, vec3f(1.0) - (vec3f(1.0) - ov) * (vec3f(1.0) - lift), dark * 0.5);
    c = mix(c, blended, min(0.8, amount * 10.0));

    // Drain the saturation, more or less per scan line.
    var hsl = to_hsl(c);
    let row = hash(vec2f(seed + 23.0, gv.y)) * 0.99 + 0.001;
    let cap = min(1.0, 1.3 - loss);
    if (hash(vec2f(seed + 19.0, gv.y)) * 0.99 + 0.001 < loss) {
        hsl.y *= (1.0 - edge(0.0, 1.0 - loss, row)) * cap;
    } else {
        hsl.y *= edge(0.0, loss, row) * cap;
    }
    c = from_hsl(hsl);
    gpufx_write(id, vec4f(clamp(c, vec3f(0.0), vec3f(1.0)), 1.0));
}
