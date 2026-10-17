// Snow falls while a glassy snowflake tumbles at the camera, fills the frame, shatters into shards and drifts off over the second clip.

// Animation timeline in seconds; the overlay is a 16:9 layer animated at 29.97 frames per second.
const SPAN: f32 = 1.53333333;
const FPS: f32 = 29.97;
const SWAP_AT: f32 = 0.8;
const LAYER_ASPECT: f32 = 1.77777778;
const PI: f32 = 3.14159265;

// Hero flake path: animation frame of each key, then (x, y) in layer uv, radius in layer heights, face-on factor.
const KEY_COUNT: u32 = 26u;
const KEY_FRAMES: array<f32, 26> = array<f32, 26>(
    7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0,
    20.0, 21.0, 22.0, 25.4, 26.0, 27.0, 28.0, 29.0, 30.0, 31.0, 32.0, 37.0, 46.0,
);
const KEYS: array<vec4f, 26> = array<vec4f, 26>(
    vec4f(0.70, -0.04, 0.06, 1.0), vec4f(0.68, 0.03, 0.07, 1.0), vec4f(0.63, 0.05, 0.08, 1.0),
    vec4f(0.55, 0.11, 0.12, 1.0), vec4f(0.48, 0.14, 0.12, 0.9), vec4f(0.47, 0.17, 0.12, 0.8),
    vec4f(0.45, 0.24, 0.12, 0.5), vec4f(0.45, 0.31, 0.12, 0.08), vec4f(0.44, 0.33, 0.13, 0.08),
    vec4f(0.47, 0.33, 0.15, 0.15), vec4f(0.42, 0.35, 0.42, 1.0), vec4f(0.40, 0.38, 0.55, 1.0),
    vec4f(0.42, 0.40, 0.70, 1.0), vec4f(0.43, 0.42, 1.0, 1.0), vec4f(0.43, 0.42, 1.5, 1.0),
    vec4f(0.43, 0.42, 2.5, 1.0), vec4f(0.62, 0.43, 0.3, 1.0), vec4f(0.62, 0.43, 0.26, 1.0),
    vec4f(0.62, 0.42, 0.22, 1.0), vec4f(0.60, 0.42, 0.18, 1.0), vec4f(0.59, 0.43, 0.16, 0.7),
    vec4f(0.60, 0.50, 0.12, 0.15), vec4f(0.60, 0.52, 0.10, 0.1), vec4f(0.62, 0.60, 0.07, 0.8),
    vec4f(0.62, 0.61, 0.06, 1.0), vec4f(0.58, 0.64, 0.05, 1.0),
);
// Frames during which the shattered crystal covers the whole layer.
const SHARDS_FROM: f32 = 22.5;
const SHARDS_TO: f32 = 25.5;

fn hash2(c: vec2f) -> vec3f {
    var q = fract(vec3f(c.xyx) * vec3f(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yxz + 33.33);
    return fract((q.xxy + q.yzz) * q.zyx);
}

fn seg_dist(p: vec2f, a: vec2f, b: vec2f) -> f32 {
    let ab = b - a;
    let h = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
    return length(p - a - ab * h);
}

// Signed distance to a six-armed flake of radius 1 (negative inside the ice).
fn flake_sdf(q: vec2f) -> f32 {
    let r = length(q);
    let sector = PI / 3.0;
    var a = atan2(q.y, q.x);
    a = abs(a - sector * round(a / sector));
    let p = vec2f(cos(a), sin(a)) * r;
    var d = seg_dist(p, vec2f(0.0), vec2f(0.92, 0.0)) - 0.055;
    d = min(d, r - 0.16);
    for (var k = 0; k < 4; k++) {
        let at = 0.26 + 0.17 * f32(k);
        let len = 0.34 - 0.07 * f32(k);
        let base = vec2f(at, 0.0);
        d = min(d, seg_dist(p, base, base + vec2f(0.5, 0.866) * len) - 0.038);
    }
    return d;
}

// Falling snow: one grid layer of soft dots drifting down; returns coverage.
fn snow_layer(q: vec2f, t: f32, cell: f32, speed: f32, size: f32, seed: f32) -> f32 {
    let g = (q + vec2f(-0.15 * speed * t, -speed * t)) / cell;
    let base = floor(g);
    var a = 0.0;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let id = base + vec2f(f32(i), f32(j));
            let r = hash2(id + seed);
            if (r.z > 0.3) { continue; }
            let centre = id + 0.5 + (r.xy - 0.5) * 0.7;
            let rad = size * (0.4 + 0.6 * fract(r.z * 7.13));
            let d = length((g - centre) * vec2f(1.0, 0.8)) / rad;
            a = max(a, (1.0 - smoothstep(0.6, 1.0, d)) * (0.45 + 0.55 * fract(r.x * 5.7)));
        }
    }
    return a;
}

// Colour and coverage of the overlay at layer point `q` (layer heights, centred) and animation frame `f`.
fn overlay(q: vec2f, f: f32, t: f32, px: f32) -> vec4f {
    if (f >= SHARDS_FROM && f < SHARDS_TO) {
        // Shattered crystal: angular facets of grey, white and pale blue.
        let s = q * 2.5 + vec2f(floor(f) * 3.1, 0.0);
        let base = floor(s);
        var best = 9.0;
        var second = 9.0;
        var pick = vec3f(0.0);
        for (var j = -1; j <= 1; j++) {
            for (var i = -1; i <= 1; i++) {
                let id = base + vec2f(f32(i), f32(j));
                let r = hash2(id + 41.0);
                let d = length(s - id - r.xy);
                if (d < best) { second = best; best = d; pick = r; } else if (d < second) { second = d; }
            }
        }
        var c = vec3f(0.12, 0.13, 0.15);
        if (pick.z > 0.66) { c = vec3f(0.88, 0.9, 0.92); } else if (pick.z > 0.33) { c = vec3f(0.55, 0.65, 0.75); }
        // Each facet catches the light along its own direction.
        let dir = vec2f(cos(pick.x * 6.28), sin(pick.x * 6.28));
        c *= 0.75 + 0.5 * clamp(0.5 + dot(s - base - pick.xy, dir), 0.0, 1.0);
        let seam = smoothstep(0.0, 0.05, second - best);
        return vec4f(c * (0.6 + 0.4 * seam), 1.0);
    }

    var cover = snow_layer(q, t, 0.035, 0.35, 0.18, 1.0);
    cover = max(cover, snow_layer(q, t, 0.07, 0.6, 0.12, 7.0));
    cover = max(cover, 0.5 * snow_layer(q, t, 0.16, 1.0, 0.1, 13.0));
    var col = vec3f(1.0);

    // Hero flake between its first and last key.
    if (f >= KEY_FRAMES[0]) {
        var k = 0u;
        for (var i = 0u; i < KEY_COUNT - 1u; i++) {
            if (f >= KEY_FRAMES[i]) { k = i; }
        }
        let k1 = min(k + 1u, KEY_COUNT - 1u);
        let w = clamp((f - KEY_FRAMES[k]) / max(KEY_FRAMES[k1] - KEY_FRAMES[k], 1e-3), 0.0, 1.0);
        let a = KEYS[k];
        let b = KEYS[k1];
        let centre = (mix(a.xy, b.xy, w) - 0.5) * vec2f(LAYER_ASPECT, 1.0);
        let radius = exp(mix(log(a.z), log(b.z), w));
        let face = max(mix(a.w, b.w, w), 0.04);
        // Tilt squashes the flake across a line leaning down to the right.
        let tilt = radians(-26.0);
        var rel = q - centre;
        rel = vec2f(dot(rel, vec2f(cos(tilt), sin(tilt))), dot(rel, vec2f(-sin(tilt), cos(tilt))) / face);
        let spin = 0.25 + f * 0.02;
        rel = vec2f(rel.x * cos(spin) - rel.y * sin(spin), rel.x * sin(spin) + rel.y * cos(spin));
        let d = flake_sdf(rel / radius);
        let aa = px / (radius * face) * 1.5;
        let inside = 1.0 - smoothstep(-aa, aa, d);
        if (inside > 0.0) {
            // Glassy ice: bright rims and spine, darker translucent body.
            let depth = clamp(-d / 0.06, 0.0, 1.0);
            let ice = mix(vec3f(0.95, 0.97, 1.0), vec3f(0.5, 0.57, 0.66), smoothstep(0.05, 0.5, depth));
            let spine = 1.0 - smoothstep(0.0, 0.5, abs(depth - 1.0));
            let flake = mix(ice, vec3f(0.85, 0.9, 0.96), 0.3 * spine);
            cover = max(cover, inside);
            col = mix(vec3f(1.0), flake, inside / max(cover, 1e-4));
        }
    }
    return vec4f(col, cover);
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

    // Layer fades in over the first 0.1667 s and out between 1.3333 s and 1.5 s.
    let fade = clamp(t / 0.166667, 0.0, 1.0) * (1.0 - clamp((t - 1.333333) / 0.166667, 0.0, 1.0));
    if (fade <= 0.0) {
        gpufx_write(id, vec4f(base, 1.0));
        return;
    }

    // 16:9 layer scaled to cover the frame, centred.
    let aspect = globals.size.x / globals.size.y;
    var v = uv - 0.5;
    var px: f32;
    if (aspect < LAYER_ASPECT) {
        v.x *= aspect / LAYER_ASPECT;
        px = 1.0 / globals.size.y;
    } else {
        v.y *= LAYER_ASPECT / aspect;
        px = LAYER_ASPECT / (aspect * globals.size.y);
    }
    let q = v * vec2f(LAYER_ASPECT, 1.0);
    // The layer's animation runs two frames behind the clock.
    let o = overlay(q, t * FPS - 2.0, t, px);
    gpufx_write(id, vec4f(mix(base, o.rgb, o.a * fade), 1.0));
}
