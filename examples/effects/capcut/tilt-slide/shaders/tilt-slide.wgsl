// The frame pulls back into a rounded card, a strip of cards (first, second, first, second) slides left
// with a perspective tilt, and the second clip's card comes forward to fill the frame.

// Length of the animation in seconds; `progress` maps onto it.
const SPAN: f32 = 2.0;
// Horizontal field of view of the virtual camera, in degrees.
const FOV_X: f32 = 39.5977527;
// Layout of the 1080-wide design: card centres relative to the strip origin, in design pixels.
const DESIGN_W: f32 = 1080.0;
const CARD_OFFSETS: array<f32, 4> = array<f32, 4>(-649.160492, 554.851151, 1794.452972, -1871.983047);
// Which clip each card shows: 0 = first, 1 = second.
const CARD_CLIPS: array<i32, 4> = array<i32, 4>(0, 1, 0, 1);
// Corner radius (0..256 of half the short edge) and edge softness.
const CORNER: f32 = 100.0;
const SOFTNESS: f32 = 5.0;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var s = x;
    for (var i = 0; i < 10; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        let dx = 3.0 * inv * inv * c.x + 6.0 * inv * s * (c.z - c.x) + 3.0 * s * s * (1.0 - c.z);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

fn ramp(t: f32, t0: f32, t1: f32, c: vec4f) -> f32 {
    return bezier_ease(clamp((t - t0) / (t1 - t0), 0.0, 1.0), c);
}

// Strip origin (x) and push-back depth (z), both in design pixels.
fn strip_motion(t: f32) -> vec2f {
    var x = 1239.160492;
    var z = 800.0 * ramp(t, 0.0, 0.333333, vec4f(0.333333, 0.0, 0.666667, 1.0));
    if (t >= 0.5) {
        x = mix(1239.160492, 29.160492, ramp(t, 0.5, 1.5, vec4f(1.0, 0.0, 0.59, 1.0)));
    }
    if (t >= 1.666667) {
        let k = ramp(t, 1.666667, 1.966667, vec4f(0.41, 0.0, 0.666667, 1.0));
        x = mix(29.160492, 35.160492, k);
        z = mix(800.0, 0.0, k);
    }
    return vec2f(x, z);
}

// Tilt of every card about its vertical axis, in degrees.
fn tilt(t: f32) -> f32 {
    if (t < 1.166667) { return -25.0 * ramp(t, 0.5, 1.166667, vec4f(0.333333, 0.0, 0.666667, 1.0)); }
    return -25.0 * (1.0 - ramp(t, 1.166667, 1.666667, vec4f(0.333333, 0.0, 0.833333, 1.0)));
}

// Corner radius of card `k` at time `t` (the cards that start and end full-frame are square then).
fn corner_of(k: i32, t: f32) -> f32 {
    let lin = vec4f(0.166667, 0.166667, 0.833333, 0.833333);
    if (k == 0) { return CORNER * ramp(t, 0.0, 0.066667, lin); }
    if (k == 1) { return CORNER * (1.0 - ramp(t, 1.9, 1.966667, lin)); }
    return CORNER;
}

// Soft rounded-rectangle coverage at texture coordinate `uv` of a card.
fn card_mask(uv: vec2f, corner: f32) -> f32 {
    let size = globals.size;
    let half_size = size * 0.5;
    let half_min = min(size.x, size.y) * 0.5;
    let r = half_min * corner / 256.0;
    let q = abs(uv * size - half_size) - (half_size - vec2f(r));
    let dist = length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
    let lo = -(half_min * SOFTNESS / 256.0) - 0.1;
    return smoothstep(lo, 0.0, -dist);
}

fn sample_clip(which: i32, uv: vec2f) -> vec4f {
    if (which == 0) { return textureSampleLevel(first, smp, uv, 0.0); }
    return textureSampleLevel(second, smp, uv, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let progress = clamp(params.progress, 0.0, 1.0);
    // Exact clips at the ends of the transition.
    if (progress <= 0.0) { gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0)); return; }
    if (progress >= 1.0) { gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0)); return; }

    let t = progress * SPAN;
    let aspect = globals.size.x / globals.size.y;
    // Scene units: the frame spans x in [-aspect, aspect], y in [-1, 1] at z = 0.
    let eye_dist = aspect / tan(radians(FOV_X * 0.5));
    let unit = 2.0 * aspect / DESIGN_W;
    let motion = strip_motion(t);
    let depth = motion.y * unit;
    let angle = radians(-tilt(t));
    let axis = vec3f(cos(angle), 0.0, -sin(angle));
    let normal = vec3f(sin(angle), 0.0, cos(angle));

    let eye = vec3f(0.0, 0.0, eye_dist);
    let ray = vec3f((uv.x * 2.0 - 1.0) * aspect, 1.0 - uv.y * 2.0, -eye_dist);
    let facing = dot(ray, normal);

    var best = 1e9;
    var color = vec4f(0.0, 0.0, 0.0, 1.0);
    if (abs(facing) > 1e-6) {
        for (var k = 0; k < 4; k++) {
            let centre = vec3f((motion.x - 50.0 + CARD_OFFSETS[k] - 540.0) * unit, 0.0, -depth);
            let hit_t = dot(centre - eye, normal) / facing;
            if (hit_t <= 0.0 || hit_t >= best) { continue; }
            let local = eye + ray * hit_t - centre;
            let card_uv = vec2f(dot(local, axis) / aspect * 0.5 + 0.5, 0.5 - local.y * 0.5);
            if (any(card_uv < vec2f(0.0)) || any(card_uv > vec2f(1.0))) { continue; }
            let cover = card_mask(card_uv, corner_of(k, t));
            if (cover <= 0.0) { continue; }
            best = hit_t;
            let c = sample_clip(CARD_CLIPS[k], card_uv);
            color = vec4f(c.rgb * cover, 1.0);
        }
    }
    gpufx_write(id, color);
}
