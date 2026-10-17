// A blizzard of streaking snow builds into a white-out that hides a dip from the first clip to the second, then clears.

// The snow runs over 30 animation frames across the whole transition.
const FRAMES: f32 = 30.0;
// The snow is laid out on a 720x1280 portrait sheet that covers the frame.
const SHEET: vec2f = vec2f(720.0, 1280.0);
// Animation frames by which the snow lags the clip fades.
const SNOW_DELAY: f32 = 1.2;

fn hash3(c: vec2i, salt: u32) -> vec3f {
    var v = vec3u(bitcast<u32>(c.x), bitcast<u32>(c.y), salt);
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v = v ^ (v >> vec3u(16u));
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return vec3f(v & vec3u(0xffffffu)) / 16777216.0;
}

fn value_noise(p: vec2f) -> f32 {
    let i = vec2i(floor(p));
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash3(i, 7u).x;
    let b = hash3(i + vec2i(1, 0), 7u).x;
    let c = hash3(i + vec2i(0, 1), 7u).x;
    let d = hash3(i + vec2i(1, 1), 7u).x;
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn cloud(p: vec2f) -> f32 {
    var sum = 0.0;
    var amp = 0.55;
    var q = p;
    for (var i = 0; i < 4; i++) {
        sum += amp * value_noise(q);
        q = q * 2.03 + vec2f(5.2, 1.3);
        amp *= 0.5;
    }
    return sum / 1.0;
}

// Ramp from 0 at a to 1 at b.
fn ramp(x: f32, a: f32, b: f32) -> f32 {
    return clamp((x - a) / (b - a), 0.0, 1.0);
}

// Overall white-out strength per animation frame: it swells from frame 12, peaks at 17 and clears by 25.
fn fog_level(f: f32) -> f32 {
    let keys = array<f32, 15>(0.0, 0.02, 0.23, 0.42, 0.54, 0.62, 0.69, 0.59, 0.41, 0.22, 0.16, 0.09, 0.035, 0.004, 0.0);
    let s = f - 11.0;
    if (s <= 0.0 || s >= 14.0) { return 0.0; }
    let i = i32(floor(s));
    return mix(keys[i], keys[i + 1], s - f32(i));
}

// Distance from p to a capsule centred at the origin along dir with half length h.
fn capsule(p: vec2f, dir: vec2f, h: f32) -> f32 {
    let t = clamp(dot(p, dir), -h, h);
    return length(p - dir * t);
}

// One layer of streaks; cell is the grid size in sheet px, size scales the streaks.
fn streaks(px: vec2f, f: f32, cell: f32, size: f32, blur: f32, salt: u32, chance: f32) -> f32 {
    var best = 0.0;
    let g = px / cell;
    let base = vec2i(floor(g));
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let c = base + vec2i(x, y);
            let r = hash3(c, salt);
            if (r.z > chance) { continue; }
            let r2 = hash3(c, salt + 101u);
            // Mostly near-horizontal streaks blown about by the wind.
            let ang = (r2.x - 0.5) * 1.4 + select(0.0, 1.3, r2.y > 0.85);
            let dir = vec2f(cos(ang), sin(ang));
            let speed = mix(6.0, 16.0, r2.z) * size;
            let centre = (vec2f(c) + 0.5 + (r.xy - 0.5) * 0.8) * cell + (dir * 0.6 + vec2f(0.0, 0.8)) * speed * (f - 15.0) / 1.0;
            let len = mix(3.0, 10.0, r.x) * size;
            let thick = mix(0.7, 1.3, r.y) * size;
            let d = capsule(px - centre, dir, len);
            let a = (1.0 - smoothstep(thick - 0.8 - blur, thick + 0.8 + blur, d)) * mix(0.45, 0.85, r2.y);
            best = max(best, a);
        }
    }
    return best;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let p = params.progress;

    // The first clip fades to black while the second fades in over it.
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb * (1.0 - ramp(p, 0.333333, 0.566667));
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    let clip = mix(a, b, ramp(p, 0.433333, 0.666667));

    // Sheet pixel under this output pixel (the sheet covers the frame, centred).
    let cover = max(globals.size.x / SHEET.x, globals.size.y / SHEET.y);
    let px = (uv - 0.5) * globals.size / cover + SHEET * 0.5;
    // The snow sheet starts a little late against the clip fades.
    let f = p * FRAMES - SNOW_DELAY;

    // Streaks sweep in from the left over the first frames, hold, then thin out.
    let front = mix(-0.1, 1.4, ramp(f, 0.5, 12.5)) * SHEET.x;
    let reach = 1.0 - smoothstep(front - 220.0, front, px.x);
    let amount = ramp(f, 0.5, 6.0) * (1.0 - ramp(f, 21.0, 27.0)) * reach;
    var flakes = 0.0;
    if (amount > 0.0) {
        flakes = max(streaks(px, f, 34.0, 1.0, 0.0, 11u, 0.3), streaks(px, f, 70.0, 1.7, 1.0, 23u, 0.15));
        // A few large out-of-focus flakes drift close to the camera.
        flakes = max(flakes, 0.7 * streaks(px, f, 260.0, 4.0, 10.0, 37u, 0.25));
        flakes *= amount;
    }

    let level = fog_level(f);
    var fog = 0.0;
    if (level > 0.0) {
        let n = cloud(px / 300.0 + vec2f(f * 0.04, -f * 0.02));
        fog = clamp(level * (1.0 + 0.9 * (n - 0.5)), 0.0, 1.0);
    }

    let white = 1.0 - (1.0 - fog) * (1.0 - flakes);
    gpufx_write(id, vec4f(mix(clip, vec3f(1.0), white), 1.0));
}
