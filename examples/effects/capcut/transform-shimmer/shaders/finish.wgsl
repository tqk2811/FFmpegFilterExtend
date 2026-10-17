// Transform Shimmer, pass 3: vertical half of the blur, then golden sparkles added on top.
//
// The sparkles live on a 1280x720 sheet scaled to cover the frame, so a square or
// portrait frame shows the middle of it, like a full-frame overlay clip.

const SPAN: f32 = 1.1666667;
const GAMMA: f32 = 2.2;
const MAX_TAPS: i32 = 64;
const SHEET: vec2f = vec2f(1280.0, 720.0);
const GOLD: vec3f = vec3f(1.0, 0.8, 0.45);

fn strength(t: f32) -> f32 {
    if (t < 0.5) { return 100.0 * t; }
    return max(50.0 * (1.0 - (t - 0.5) / 0.5), 0.0);
}

fn taps(s: f32) -> f32 {
    var n: f32;
    if (s <= 30.0) { n = (0.5 * s + 2.0) * 0.78; }
    else if (s <= 100.0) { n = (0.5 * s + 10.0) * 0.66; }
    else { n = (0.25 * s + 50.0) * 0.7; }
    if (n < 2.0) { n = floor(n + 0.5); }
    return n;
}

fn lin(q: vec2f) -> vec3f {
    return pow(textureSampleLevel(blur_h, smp, q, 0.0).rgb, vec3f(GAMMA));
}

fn blurred(uv: vec2f, s: f32) -> vec3f {
    let n = taps(s);
    if (s <= 0.01 || n < 1e-5) { return textureSampleLevel(blur_h, smp, uv, 0.0).rgb; }
    let base = max(min(globals.size.x, globals.size.y), max(globals.size.x, globals.size.y) * 0.5);
    let radius = base / globals.size.y * s / 1000.0;
    let sigma = radius / 2.5;
    let stride = radius / n;
    var sum = lin(uv);
    var total = 1.0;
    for (var i = 1; i <= MAX_TAPS; i++) {
        let k = f32(i);
        if (k > n) { break; }
        let d = k * stride;
        let w = exp(-0.5 * d * d / (sigma * sigma));
        if (uv.y - d >= 0.0) { sum += lin(vec2f(uv.x, uv.y - d)) * w; total += w; }
        if (uv.y + d <= 1.0) { sum += lin(vec2f(uv.x, uv.y + d)) * w; total += w; }
    }
    return pow(sum / total, vec3f(1.0 / GAMMA));
}

fn rand4(c: vec2f, salt: f32) -> vec4f {
    var p = fract(vec4f(c.xyxy + vec4f(salt, salt * 1.7, salt * 2.3, salt * 3.1)) * vec4f(0.1031, 0.1030, 0.0973, 0.1099));
    p += dot(p, p.wzxy + 33.33);
    return fract((p.xxyz + p.yzzw) * p.zywx);
}

// One layer of sparkles: at most one dot per cell, `chance` of a cell having one.
fn sparkle_layer(q: vec2f, t: f32, cell: f32, chance: f32, rmin: f32, rmax: f32, salt: f32) -> f32 {
    let home = floor(q / cell);
    var light = 0.0;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let c = home + vec2f(f32(i), f32(j));
            let r = rand4(c, salt);
            if (r.w > chance) { continue; }
            let r2 = rand4(c, salt + 17.0);
            let drift = (r2.xy - 0.5) * vec2f(60.0, 60.0) + vec2f(0.0, -25.0);
            let centre = (c + r.xy) * cell + drift * t;
            let size = mix(rmin, rmax, r.z * r.z);
            let d = length(q - centre) / size;
            let twinkle = 0.55 + 0.45 * sin(6.2831853 * (r2.z + t * mix(0.4, 1.4, r2.w)));
            let peak = mix(0.35, 0.95, r2.w) * twinkle;
            light += peak * (1.0 - smoothstep(0.55, 1.0, d));
        }
    }
    return light;
}

fn sparkles(uv: vec2f, t: f32) -> vec3f {
    let scale = max(globals.size.x / SHEET.x, globals.size.y / SHEET.y);
    let q = (uv - 0.5) * globals.size / scale + SHEET * 0.5;
    var light = sparkle_layer(q, t, 48.0, 0.45, 1.5, 4.0, 3.0);
    light += sparkle_layer(q, t, 140.0, 0.35, 5.0, 11.0, 41.0) * 0.8;
    // The sparkle sheet fades in and out over its first and last few frames.
    let fade = smoothstep(0.0, 0.15, t) * smoothstep(SPAN, SPAN - 0.15, t);
    return GOLD * light * fade;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let color = blurred(uv, strength(t)) + sparkles(uv, t);
    gpufx_write(id, vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), 1.0));
}
