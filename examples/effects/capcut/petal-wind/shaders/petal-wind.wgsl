// Red rose petals blow in from the left, fill the frame and thin out while the first clip dissolves into the second.

// The transition plays two seconds of animation time.
const SPAN: f32 = 2.0;
const PI: f32 = 3.14159265;
// Number of petal depth layers (0 = nearest).
const LAYERS: i32 = 5;

fn hash21(p: vec2f, salt: f32) -> f32 {
    var q = fract(p * vec2f(127.13, 311.71) + salt * 0.1731);
    q += dot(q, q.yx + 19.19);
    return fract((q.x + q.y) * q.x);
}

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * x1 + 3.0 * inv * s * s * x2 + s * s * s;
        let dx = 3.0 * inv * inv * x1 + 6.0 * inv * s * (x2 - x1) + 3.0 * s * s * (1.0 - x2);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * y1 + 3.0 * inv * s * s * y2 + s * s * s;
}

// Horizontal position the gust has reached at time t (field units, 0 = left edge).
fn gust_front(t: f32) -> f32 {
    if (t < 0.3) { return mix(-0.08, 0.25, (t - 0.05) / 0.25); }
    if (t < 0.5) { return mix(0.25, 0.5, (t - 0.3) / 0.2); }
    if (t < 0.65) { return mix(0.5, 0.8, (t - 0.5) / 0.15); }
    return mix(0.8, 1.2, (t - 0.65) / 0.15);
}

struct LayerSpec {
    cell: f32,
    radius: f32,
    blur: f32,
    fill: f32,
    fall: vec2f,
};

fn layer_spec(i: i32) -> LayerSpec {
    switch (i) {
        case 0: { return LayerSpec(0.42, 0.13, 0.05, 0.35, vec2f(0.20, 0.30)); }
        case 1: { return LayerSpec(0.12, 0.034, 0.004, 0.85, vec2f(0.12, 0.24)); }
        case 2: { return LayerSpec(0.092, 0.027, 0.003, 0.85, vec2f(0.10, 0.20)); }
        case 3: { return LayerSpec(0.072, 0.021, 0.0025, 0.85, vec2f(0.08, 0.17)); }
        default: { return LayerSpec(0.056, 0.016, 0.004, 0.85, vec2f(0.06, 0.14)); }
    }
}

// Coverage of one petal at `q` (field units relative to its centre); returns (alpha, shade).
fn petal(q: vec2f, radius: f32, blur: f32, spin: f32, tilt: f32) -> vec2f {
    let cs = cos(spin);
    let sn = sin(spin);
    var l = vec2f(cs * q.x + sn * q.y, -sn * q.x + cs * q.y) / radius;
    // A tumbling petal seen edge-on gets thinner across.
    l.x /= max(abs(tilt), 0.18);
    // Rounded cup, wider at the top and narrowing to the stem end.
    let width = 1.0 + 0.32 * l.y;
    let d = length(vec2f(l.x / max(width, 0.3), l.y * 0.85)) - 1.0;
    let soft = (blur / radius) + 0.06;
    let a = 1.0 - smoothstep(-soft, soft, d);
    let shade = clamp(0.62 + 0.38 * (-l.y * 0.6 + l.x * 0.25 * sign(tilt)), 0.25, 1.0);
    return vec2f(a, shade);
}

// Composites the petal layers over `base` at field position `c`.
fn petals_over(base: vec3f, c: vec2f, t: f32) -> vec3f {
    var color = base;
    let front = gust_front(t - 0.06);
    for (var li = LAYERS - 1; li >= 0; li--) {
        let spec = layer_spec(li);
        // Petals of this layer ride a common downwind drift.
        let drift = spec.fall * t;
        let local = (c - drift) / spec.cell;
        let home = floor(local);
        for (var j = -1; j <= 1; j++) {
            for (var i = -1; i <= 1; i++) {
                let cell = home + vec2f(f32(i), f32(j));
                let salt = f32(li) * 13.0;
                if (hash21(cell, salt + 1.0) > spec.fill) { continue; }
                let jitter = vec2f(hash21(cell, salt + 2.0), hash21(cell, salt + 3.0));
                let phase = hash21(cell, salt + 4.0) * 2.0 * PI;
                let wobble = vec2f(sin(t * 3.1 + phase), cos(t * 2.3 + phase * 1.7)) * 0.12;
                let centre = (cell + 0.15 + 0.7 * jitter + wobble) * spec.cell + drift;
                // Petals enter with the gust (the top leads slightly) and leave at their own time.
                let reach = front - (centre.x + 0.25 * (centre.y - 0.5)) + 0.08 * hash21(cell, salt + 5.0);
                var life = smoothstep(0.0, 0.06, reach);
                let early = hash21(cell, salt + 6.0) < 0.42;
                var leave = 1.2 + 0.4 * hash21(cell, salt + 7.0);
                if (early) { leave = 0.74 + 0.12 * hash21(cell, salt + 7.0); }
                if (li == 0) { leave = 0.62 + 0.25 * hash21(cell, salt + 7.0); }
                life *= 1.0 - smoothstep(leave - 0.08, leave, t);
                if (life <= 0.0) { continue; }
                let size = spec.radius * (0.7 + 0.6 * hash21(cell, salt + 8.0));
                let spin = phase + t * (hash21(cell, salt + 9.0) - 0.5) * 6.0;
                let tilt = cos(phase * 1.3 + t * (2.0 + 3.0 * hash21(cell, salt + 10.0)));
                let pc = petal(c - centre, size, spec.blur, spin, tilt);
                if (pc.x <= 0.0) { continue; }
                var tint = vec3f(0.97, 0.2, 0.24) * pc.y;
                if (li == 0) { tint *= 0.5; }
                color = mix(color, tint, pc.x * life);
            }
        }
    }
    return color;
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
    let t = p * SPAN;
    let outgoing = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let incoming = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Dissolve between 0.5 s and 1.1667 s of the animation.
    let k = clamp((t - 0.5) / 0.666667, 0.0, 1.0);
    let base = mix(outgoing, incoming, bezier_ease(k, 0.166667, 0.166667, 0.833333, 0.833333));

    // Square petal field covering the frame, centred, sized by the longer side.
    let side = max(globals.size.x, globals.size.y);
    let c = (uv - 0.5) * globals.size / side + 0.5;
    gpufx_write(id, vec4f(petals_over(base, c, t), 1.0));
}
