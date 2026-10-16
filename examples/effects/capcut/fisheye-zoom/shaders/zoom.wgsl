// Fisheye zoom, step 2: zoom-blur the shrinking disc and lay it over the second clip, which unbends from its own fisheye.

fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(e.x, e.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(e.y, e.w, 0.5 * (lo + hi));
}

// Zoom blur amount: 0 -> 15 by the middle, 15 -> 30 by 83 %.
fn blur_amount(t: f32) -> f32 {
    if (t < 0.166667) { return 0.0; }
    if (t < 0.5) {
        return mix(0.0, 15.0, ease(vec4f(0.1666667, 0.0, 0.8333333, 1.0), (t - 0.166667) / 0.333333));
    }
    return mix(15.0, 30.0, ease(vec4f(0.3333333, 0.0, 0.6666667, 1.0), clamp((t - 0.5) / 0.333333, 0.0, 1.0)));
}

// Lens strength on the second clip: 100 until 60 %, then eased out to 0.
fn second_bend(t: f32) -> f32 {
    return mix(100.0, 0.0, ease(vec4f(0.3333333, 0.0, 0.0, 1.0), clamp((t - 0.6) / 0.4, 0.0, 1.0)));
}

fn jitter(p: vec2f) -> f32 {
    let f = fract(p * 13.517);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

fn second_clip(uv: vec2f, strength: f32) -> vec3f {
    let aspect = globals.size.x / globals.size.y;
    let size = 140.0 * pow(1.6, aspect - 1.0);
    var d = uv - vec2f(0.5);
    d.x *= aspect;
    let dist = length(d);
    let edge = size * 0.007;
    let inside = smoothstep(edge + 0.001, edge - 0.001, dist);
    let bent = dist * (1.0 - strength * 203.0875 / (size * size) * dist * dist);
    var q = vec2f(0.0);
    if (dist > 0.0) { q = d / dist * bent; }
    q.x /= aspect;
    q += vec2f(0.5);
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return vec3f(0.0); }
    return textureSampleLevel(second, smp, q, 0.0).rgb * inside;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress;

    // Straight zoom blur toward the centre; taps past the frame edge count as empty.
    let amount = blur_amount(t) / 200.0;
    var acc = textureSampleLevel(disc, smp, uv, 0.0);
    if (amount > 0.0) {
        let reach = (uv - vec2f(0.5)) * amount;
        let taps = min(160.0 * (0.9 * length(reach) + 0.1) + 5.0, 128.0);
        let stride = reach / taps;
        let start = uv + stride * 0.5 * (jitter(uv) * 2.0 - 1.0);
        var count = 1.0;
        for (var k = 1.0; k <= 128.0; k += 1.0) {
            if (k > taps) { break; }
            let q = start - stride * k;
            count += 1.0;
            if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
                acc += textureSampleLevel(disc, smp, q, 0.0);
            }
        }
        acc /= count;
    }
    let back = second_clip(uv, second_bend(t));
    gpufx_write(id, vec4f(acc.rgb + back * (1.0 - acc.a), 1.0));
}
