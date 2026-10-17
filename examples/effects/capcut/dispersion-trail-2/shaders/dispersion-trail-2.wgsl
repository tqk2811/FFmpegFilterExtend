// Coloured light streaks rush diagonally over the first clip, a cyan glare floods the frame white, then fades off the second clip.

// Animation timeline: 1.6 s at 30 frames per second; the clips swap at 1.1667 s.
const SPAN: f32 = 1.6;
const FPS: f32 = 30.0;
const SWAP_AT: f32 = 1.16666667;

// Glare level and its slope across the frame (x right, y down) for every animation frame.
const GLARE_KEYS: array<vec3f, 48> = array<vec3f, 48>(
    vec3f(0.0, 0.0, 0.0), vec3f(0.0, 0.0, 0.0), vec3f(0.0, 0.0, 0.0), vec3f(0.0, 0.0, 0.0),
    vec3f(0.0, -0.002, 0.001), vec3f(0.002, -0.005, 0.008), vec3f(0.005, -0.009, 0.011), vec3f(0.012, -0.027, 0.043),
    vec3f(0.02, -0.044, 0.073), vec3f(0.026, -0.058, 0.086), vec3f(0.036, -0.071, 0.105), vec3f(0.045, -0.082, 0.136),
    vec3f(0.05, -0.092, 0.156), vec3f(0.056, -0.096, 0.17), vec3f(0.066, -0.095, 0.178), vec3f(0.075, -0.089, 0.184),
    vec3f(0.083, -0.091, 0.194), vec3f(0.087, -0.084, 0.187), vec3f(0.087, -0.076, 0.163), vec3f(0.085, -0.075, 0.139),
    vec3f(0.083, -0.061, 0.129), vec3f(0.083, -0.05, 0.111), vec3f(0.085, -0.041, 0.101), vec3f(0.09, -0.076, 0.117),
    vec3f(0.423, -0.327, 0.183), vec3f(0.52, -0.349, 0.164), vec3f(0.68, -0.397, 0.177), vec3f(0.761, -0.319, 0.144),
    vec3f(0.792, -0.284, 0.142), vec3f(0.83, -0.247, 0.158), vec3f(0.872, -0.226, 0.155), vec3f(0.894, -0.219, 0.143),
    vec3f(0.929, -0.179, 0.088), vec3f(0.97, -0.047, 0.021), vec3f(0.988, -0.025, 0.007), vec3f(0.972, 0.0, 0.0),
    vec3f(0.806, 0.0, 0.0), vec3f(0.796, 0.0, -0.002), vec3f(0.773, 0.015, 0.029), vec3f(0.716, 0.088, 0.061),
    vec3f(0.632, 0.178, 0.116), vec3f(0.44, 0.201, 0.075), vec3f(0.229, 0.149, 0.026), vec3f(0.131, 0.087, 0.013),
    vec3f(0.012, 0.02, 0.001), vec3f(0.0, 0.0, 0.0), vec3f(0.0, 0.0, 0.0), vec3f(0.0, 0.0, 0.0),
);

// Strength of the streak layer for every animation frame.
const STREAK_KEYS: array<f32, 48> = array<f32, 48>(
    0.0, 0.0, 0.0, 0.01, 0.04, 0.1, 0.18, 0.3, 0.42, 0.52, 0.62, 0.7,
    0.76, 0.82, 0.88, 0.94, 1.0, 1.0, 1.0, 0.98, 0.96, 0.95, 0.95, 0.95,
    0.8, 0.65, 0.45, 0.3, 0.2, 0.12, 0.06, 0.03, 0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
);

fn hash2(c: vec2f) -> vec3f {
    var q = fract(vec3f(c.xyx) * vec3f(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yxz + 33.33);
    return fract((q.xxy + q.yzz) * q.zyx);
}

// Glare colour: dark teal through cyan up to near white.
fn glare_color(h: f32) -> vec3f {
    let x = clamp(h, 0.0, 1.0);
    if (x < 0.25) { return mix(vec3f(0.0), vec3f(0.1, 0.25, 0.27), x / 0.25); }
    if (x < 0.5) { return mix(vec3f(0.1, 0.25, 0.27), vec3f(0.25, 0.55, 0.6), (x - 0.25) / 0.25); }
    if (x < 0.75) { return mix(vec3f(0.25, 0.55, 0.6), vec3f(0.55, 0.88, 0.92), (x - 0.5) / 0.25); }
    if (x < 0.9) { return mix(vec3f(0.55, 0.88, 0.92), vec3f(0.78, 0.97, 0.98), (x - 0.75) / 0.15); }
    return mix(vec3f(0.78, 0.97, 0.98), vec3f(0.96, 0.99, 0.99), (x - 0.9) / 0.1);
}

fn streak_tint(k: f32) -> vec3f {
    if (k < 0.45) { return vec3f(0.25, 0.45, 1.0); }
    if (k < 0.7) { return vec3f(0.75, 0.3, 0.95); }
    if (k < 0.88) { return vec3f(0.2, 0.75, 1.0); }
    return vec3f(1.0, 0.45, 0.85);
}

// One layer of soft elongated blobs laid on a jittered grid, aligned with the streak direction.
fn streak_layer(q: vec2f, cell: vec2f, seed: f32, travel: f32) -> vec3f {
    let g = (q - vec2f(travel, 0.0)) / cell;
    let base = floor(g);
    var sum = vec3f(0.0);
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let id = base + vec2f(f32(i), f32(j));
            let r = hash2(id + seed);
            let centre = id + vec2f(0.5) + (r.xy - 0.5) * vec2f(0.6, 0.7);
            let d = (g - centre) * cell / (cell * vec2f(0.32, 0.16));
            let lit = exp(-dot(d, d) * 2.0);
            let pick = hash2(id + seed + 17.0);
            let keep = step(0.25, pick.y);
            sum += streak_tint(pick.x) * lit * (0.35 + 0.65 * pick.z * pick.z) * keep;
        }
    }
    return sum;
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
    var base: vec3f;
    if (t < SWAP_AT) {
        base = textureSampleLevel(first, smp, uv, 0.0).rgb;
    } else {
        base = textureSampleLevel(second, smp, uv, 0.0).rgb;
    }

    // Keyframes sampled with linear interpolation; the overlay runs about 1.5 frames behind the clock.
    let fk = clamp(t * FPS - 1.5, 0.0, 47.0);
    let k0 = u32(floor(fk));
    let k1 = min(k0 + 1u, 47u);
    let w = fk - floor(fk);
    let glare = mix(GLARE_KEYS[k0], GLARE_KEYS[k1], w);
    let streak_gain = mix(STREAK_KEYS[k0], STREAK_KEYS[k1], w);

    // The overlay is a square layer covering the frame (cropped to the longer side).
    let side = max(globals.size.x, globals.size.y);
    let s = (uv - 0.5) * globals.size / side;

    var light = glare_color(glare.x + glare.y * s.x + glare.z * s.y);
    if (streak_gain > 0.0) {
        // Streaks lean up and to the right and slide along their own axis.
        let ang = radians(55.0);
        let axis = vec2f(cos(ang), -sin(ang));
        let q = vec2f(dot(s, axis), dot(s, vec2f(-axis.y, axis.x)));
        let travel = t * 0.9;
        var streaks = streak_layer(q, vec2f(0.16, 0.05), 3.0, travel);
        streaks += 0.6 * streak_layer(q * 1.4 + 0.37, vec2f(0.16, 0.05), 11.0, travel * 1.3);
        light += streaks * streak_gain * 0.7;
    }
    gpufx_write(id, vec4f(min(base + light, vec3f(1.0)), 1.0));
}
