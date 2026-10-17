// A glowing, wobbling ring full of snowflakes grows out of the centre over a rippling cross-fade, then the flakes drift apart to the sides.

// The transition runs over 50 animation frames (2 s at 25 fps).
const FRAMES: f32 = 50.0;
const PI: f32 = 3.14159265;
// Snowflakes, rings and dots carried by the growing ring.
const FLAKES: i32 = 130;

fn hash(n: f32) -> f32 {
    return fract(sin(n * 91.3458) * 47453.5453);
}

fn hash2(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

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

// Smooth gradient noise in [0, 1]; `phase` slides the gradients so the pattern evolves.
fn gradient_noise(p: vec2f, phase: f32, salt: f32) -> f32 {
    let cell = floor(p);
    let fr = fract(p);
    let w = fr * fr * (3.0 - 2.0 * fr);
    var corners: array<f32, 4>;
    for (var k = 0; k < 4; k++) {
        let o = vec2f(f32(k & 1), f32(k >> 1));
        let seed = hash2(cell + o + salt);
        let ang = (seed + phase * (0.5 + seed)) * 2.0 * PI;
        corners[k] = dot(vec2f(cos(ang), sin(ang)), fr - o);
    }
    return mix(mix(corners[0], corners[1], w.x), mix(corners[2], corners[3], w.x), w.y) * 0.5 + 0.5;
}

// Six-armed snowflake of radius 1 in local coordinates; returns the distance to its strokes.
fn flake_dist(q: vec2f) -> f32 {
    let r = length(q);
    let sector = PI / 3.0;
    var a = atan2(q.y, q.x);
    a = abs(a - sector * round(a / sector));
    let p = vec2f(cos(a), sin(a)) * r;
    var d = select(length(p - vec2f(1.0, 0.0)), p.y, p.x <= 1.0 && p.x >= 0.0);
    for (var k = 0; k < 2; k++) {
        let base = vec2f(0.45 + 0.25 * f32(k), 0.0);
        let tip = base + vec2f(0.5, 0.866) * (0.34 - 0.1 * f32(k));
        let ab = tip - base;
        let h = clamp(dot(p - base, ab) / dot(ab, ab), 0.0, 1.0);
        d = min(d, length(p - base - ab * h));
    }
    return d;
}

// Brightness of one particle at `q` (local units), kind 0 = flake, 1 = ring, 2 = dot.
fn particle(q: vec2f, kind: f32, aa: f32) -> f32 {
    let r = length(q);
    if (r > 3.0) { return 0.0; }
    var d: f32;
    var w: f32;
    if (kind < 0.5) {
        d = flake_dist(q);
        w = 0.08;
    } else if (kind < 1.5) {
        d = abs(r - 0.75);
        w = 0.1;
    } else {
        d = r;
        w = 0.45;
    }
    let core = 1.0 - smoothstep(w - aa, w + aa, d);
    return max(core, exp(-d * 3.0) * 0.35);
}

// Radius of the ring at angle `ang` and frame `f`, with a slow wobble along its edge.
fn ring_radius(ang: f32, f: f32) -> f32 {
    let base = 0.036 * (f - 1.5);
    let dir = vec2f(cos(ang), sin(ang));
    let wobble = gradient_noise(dir * 1.6 + 7.0, f * 0.05, 3.0) - 0.5;
    return base * (1.0 + 0.6 * wobble);
}

fn snow(c: vec2f, shape: vec2f, aa_unit: f32, f: f32) -> f32 {
    var total = 0.0;
    let r = length(c);

    // The ring and the haze filling it.
    let ring_fade = smoothstep(1.5, 3.0, f) * (1.0 - smoothstep(17.0, 22.0, f));
    if (ring_fade > 0.0) {
        let edge = ring_radius(atan2(c.y, c.x), f);
        let d = r - edge;
        let line = exp(-abs(d) / 0.006) + 0.45 * exp(-abs(d) / 0.03);
        let fill = select(0.0, 0.08 + 0.3 * pow(r / max(edge, 1e-4), 3.0), d < 0.0);
        total += (line + fill) * ring_fade;
    }

    // Flakes: born inside the ring, then pushed apart to the left and right edges.
    let fade = smoothstep(1.5, 4.0, f) * pow(clamp(1.0 - (f - 16.0) / 30.0, 0.0, 1.0), 1.3);
    if (fade > 0.0) {
        let spread = smoothstep(12.0, 34.0, f);
        let grow = max(0.036 * (f - 1.5), 0.0);
        for (var i = 0; i < FLAKES; i++) {
            let n = f32(i);
            let ang = hash(n + 1.0) * 2.0 * PI;
            let rad = sqrt(hash(n + 3.0));
            var pos = vec2f(cos(ang), sin(ang)) * rad * min(grow, 0.75);
            let side = select(-1.0, 1.0, pos.x >= 0.0);
            let target_x = side * (0.27 + 0.2 * hash(n + 5.0));
            pos.x = mix(pos.x, target_x, spread);
            pos.y += (hash(n + 7.0) - 0.5) * 0.004 * f;
            // Before spreading, a flake shows only once the ring has passed it.
            let inside = 1.0 - smoothstep(0.85, 1.0, rad * min(grow, 0.75) / max(grow, 1e-4) - spread);
            let pick = hash(n + 13.0);
            var kind = 2.0;
            var size = 0.003 + 0.004 * hash(n + 17.0);
            if (pick < 0.65) {
                kind = 0.0;
                size = 0.009 + 0.008 * hash(n + 17.0);
            } else if (pick < 0.8) {
                kind = 1.0;
                size = 0.007;
            }
            // Flakes stay round even though their layout is stretched to the frame.
            let q = (c - pos) * shape / size;
            total += particle(q, kind, aa_unit / size) * (0.3 + 0.35 * hash(n + 29.0)) * inside;
        }
        total *= fade;
    }
    return clamp(total, 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    // Exact clips at the ends, so the transition joins the cut seamlessly.
    if (p <= 0.0) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    if (p >= 1.0) {
        gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    let f = p * FRAMES;
    let t = p * 2.0;

    // Turbulent ripple over the cross-fade: strength rises and settles back to none.
    let amount = select(
        keyed(t, 0.48, 0.92, 0.04, 0.0, vec4f(0.16667, 0.16667, 0.4, 1.0)),
        keyed(t, 0.0, 0.48, 0.0, 0.04, vec4f(0.4, 0.0, 0.83333, 0.83333)),
        t < 0.48);
    let evolve = select(
        keyed(t, 0.48, 0.92, 109.0, 78.0, vec4f(0.16667, 0.16667, 0.52, 1.0)),
        keyed(t, 0.0, 0.48, 0.0, 109.0, vec4f(0.48, 0.0, 0.83333, 0.83333)),
        t < 0.48) / 90.0;
    let short_side = min(globals.size.x, globals.size.y);
    let grid = uv * globals.size / short_side * 7.2;
    let nx = gradient_noise(grid, evolve, 2.11);
    let ny = gradient_noise(grid, evolve, 9.71);
    let push = (vec2f(nx, ny) - 0.5) * amount * 3.0 * short_side / globals.size;
    var suv = uv + push;
    suv = 1.0 - abs(1.0 - abs(suv));

    let outgoing = textureSampleLevel(first, smp, suv, 0.0).rgb;
    let incoming = textureSampleLevel(second, smp, suv, 0.0).rgb;
    // The second clip fades in from black during frames 4..8, the first fades out over it during 5..10.
    let under = incoming * clamp((f - 4.0) / 4.0, 0.0, 1.0);
    let base = mix(under, outgoing, 1.0 - clamp((f - 5.0) / 5.0, 0.0, 1.0));

    // Square snow layer stretched over the whole frame, so the ring and the flakes' paths
    // always fit; flake shapes are measured along the longer side to stay round.
    let side = max(globals.size.x, globals.size.y);
    let c = uv - 0.5;
    let light = snow(c, globals.size / side, 1.0 / side, f);
    let color = 1.0 - (1.0 - base) * (1.0 - light);
    gpufx_write(id, vec4f(color, 1.0));
}
