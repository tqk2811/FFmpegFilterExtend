// Glassblock Zoom 2, pass 1: pick the clip on screen and split its red and blue channels apart.
//
// `progress` 0..1 spans 2 s of animation time. The first clip shows up to 1 s inclusive, the second after it.
// The red channel is sampled ahead and the blue one behind by an offset that vanishes at the
// borders and peaks in the middle of the frame.

// Channel split at full strength, as a fraction of the frame.
const SPLIT_GAIN: f32 = 0.2;

fn cubic(p1: f32, p2: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * p1 * r * r * s + 3.0 * p2 * r * s * s + s * s * s;
}

// y(x) of the bezier (0,0)-(k.x,k.y)-(k.z,k.w)-(1,1).
fn ease(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 16; n++) {
        let mid = (lo + hi) * 0.5;
        if (cubic(k.x, k.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return cubic(k.y, k.w, (lo + hi) * 0.5);
}

fn span(t: f32, t0: f32, t1: f32, a: f32, b: f32, k: vec4f) -> f32 {
    return mix(a, b, ease(k, (t - t0) / (t1 - t0)));
}

// Shared shape of both channel-split curves: rise, dip (x) or surge (y) at 1 s, fall.
fn split_curve(t: f32, rise: f32, peak: f32) -> f32 {
    let slow = vec4f(0.66, 0.0, 0.34, 1.0);
    if (t < rise) { return 0.0; }
    if (t < 0.833333) { return span(t, rise, 0.833333, 0.0, 0.3, slow); }
    if (t < 1.0) { return span(t, 0.833333, 1.0, 0.3, peak, vec4f(0.66, 0.0, 0.83, 1.0)); }
    if (t < 1.166667) { return span(t, 1.0, 1.166667, peak, 0.3, vec4f(0.17, 0.0, 0.34, 1.0)); }
    if (t < 1.633333) { return span(t, 1.166667, 1.633333, 0.3, 0.0, slow); }
    return 0.0;
}

fn clip_at(uv: vec2f, late: bool) -> vec4f {
    if (late) { return textureSampleLevel(second, smp, uv, 0.0); }
    return textureSampleLevel(first, smp, uv, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = params.progress * 2.0;
    let late = t > 1.0;
    let base = clip_at(uv, late);
    let amount = vec2f(split_curve(t, 0.533333, 0.1), split_curve(t, 0.466667, 1.0)) * SPLIT_GAIN;
    if (amount.x == 0.0 && amount.y == 0.0) {
        gpufx_write(id, base);
        return;
    }
    // The vertical axis of the offset points up the picture.
    let shift = amount * (1.0 - uv) * uv * vec2f(1.0, -1.0);
    let ahead = clip_at(uv + shift, late);
    let behind = clip_at(uv - shift, late);
    gpufx_write(id, vec4f(ahead.r, base.g, behind.b, (ahead.a + base.a + behind.a) / 3.0));
}
