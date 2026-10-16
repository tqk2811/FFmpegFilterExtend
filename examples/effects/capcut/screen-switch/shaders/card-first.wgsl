// Screen Switch, pass 1 (keep in sync with card-second.wgsl): the outgoing clip as a rounded card seen through a curved lens.

// The animation runs over 2 s of timeline.
const TIMELINE: f32 = 2.0;

fn timeline_now() -> f32 { return clamp(params.progress, 0.0, 1.0) * TIMELINE; }

fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

// Keyframe easing: find s where the x axis reaches u, return the y axis there.
fn ease(k: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(k.x, k.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(k.y, k.w, 0.5 * (lo + hi));
}

// One keyframe segment: keeps `cur` before t0, eases from v0 to v1 inside, holds v1 after.
fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, k: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return v0 + (v1 - v0) * ease(k, (t - t0) / (t1 - t0));
}

const LINEAR = vec4f(0.166666667, 0.166666667, 0.833333333, 0.833333333);
const SMOOTH = vec4f(0.333333, 0.0, 0.666667, 1.0);

// Card state: x = corner radius (of 256), y = lens strength (degrees), z = height of the centre
// measured from the bottom (0..1), w = scale.
fn outgoing_state(t: f32) -> vec4f {
    let radius = key(0.0, t, 0.533333, 0.633333, 0.0, 50.0, LINEAR);
    let lens = key(0.0, t, 0.633333, 1.0, 0.0, 20.0, LINEAR);
    let y = key(0.5, t, 1.133333, 1.4, 0.5, 1.6859205776174, LINEAR);
    let s = key(1.0, t, 0.4, 1.133333, 1.0, 0.8, LINEAR);
    return vec4f(radius, lens, y, s);
}

fn incoming_state(t: f32) -> vec4f {
    let radius = key(50.0, t, 1.7, 1.9, 50.0, 0.0, LINEAR);
    let lens = key(20.0, t, 1.533333, 1.866667, 20.0, 0.0, LINEAR);
    let y = key(-0.43772563176934, t, 1.133333, 1.4, -0.43772563176934, 0.5, SMOOTH);
    var s = key(1.0, t, 0.4, 1.133333, 1.0, 0.8, LINEAR);
    s = key(s, t, 1.666667, 1.933333, 0.8, 1.0, LINEAR);
    return vec4f(radius, lens, y, s);
}

// The clip with rounded corners, seen through a barrel lens; q is bottom-up 0..1, result premultiplied.
fn card(tex: texture_2d<f32>, q: vec2f, radius: f32, lens: f32) -> vec4f {
    let size = globals.size;
    let i = lens / 180.0;
    let k2 = 22.759 * pow(i, 3.167) + 0.431 * i;
    let d = q - 0.5;
    let dy = d.y * size.y / size.x;
    let f = 1.0 / (1.0 - k2 * (d.x * d.x + dy * dy));
    let p = 0.5 + d * f;
    if (f <= 0.0 || any(p < vec2f(0.0)) || any(p > vec2f(1.0))) { return vec4f(0.0); }
    let half_edge = min(size.x, size.y) * 0.5;
    let r = half_edge * radius / 256.0;
    let soft = half_edge * 0.5 * 5.0 / 256.0 + 0.05;
    let px = p * size;
    let e = abs(px - size * 0.5) - (size * 0.5 - vec2f(r));
    let dist = length(max(e, vec2f(0.0))) + min(max(e.x, e.y), 0.0) - r;
    let cover = smoothstep(-soft, soft, -dist);
    let c = textureSampleLevel(tex, smp, vec2f(p.x, 1.0 - p.y), 0.0);
    return vec4f(c.rgb * c.a, c.a) * cover;
}

fn luma(c: vec4f) -> f32 { return dot(c.rgb, vec3f(0.299, 0.587, 0.114)); }

fn shaped(q: vec2f) -> vec4f {
    let st = outgoing_state(timeline_now());
    return card(first, q, st.x, st.y);
}

// Edge smoothing along the local gradient, as the lens stage applies after warping.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let q = vec2f(uv.x, 1.0 - uv.y);
    let px = 1.0 / globals.size;
    let nw = shaped(q + vec2f(-1.0, -1.0) * px);
    let ne = shaped(q + vec2f(1.0, -1.0) * px);
    let sw = shaped(q + vec2f(-1.0, 1.0) * px);
    let se = shaped(q + vec2f(1.0, 1.0) * px);
    let l_nw = luma(nw);
    let l_ne = luma(ne);
    let l_sw = luma(sw);
    let l_se = luma(se);
    // Deliberate: the middle sample is read at q * px, not q. This reproduces a quirk of the reference and matches the demo; do not "fix" it.
    let l_m = luma(shaped(q * px));
    let upper = l_nw + l_ne;
    var dir = vec2f(-(upper - (l_sw + l_se)), (l_nw + l_sw) - (l_ne + l_se));
    let reduce = max((upper + l_sw + l_se) * 0.03125, 0.0078125);
    dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), vec2f(-8.0), vec2f(8.0)) * px;
    let near = (shaped(q - dir / 6.0) + shaped(q + dir / 6.0)) * 0.5;
    let far = (shaped(q - dir * 0.5) + shaped(q + dir * 0.5)) * 0.25;
    let l = luma(near);
    let lo = min(l_m, min(min(l_nw, l_ne), min(l_sw, l_se)));
    let hi = max(l_m, max(max(l_nw, l_ne), max(l_sw, l_se)));
    var c = near * 0.5 + far;
    if (l < lo || l > hi) { c = near; }
    gpufx_write(id, c);
}
