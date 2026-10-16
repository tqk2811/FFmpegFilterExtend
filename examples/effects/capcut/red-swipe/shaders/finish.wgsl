// Red Swipe, pass 4: lay the sorted streaks back over the picture and paint the red channel from a brightness-driven colour wheel.

const STRIP_COLS: u32 = 256u;
const CLOCK_START: f32 = 0.46713380046713;
const CLOCK_END: f32 = 1.46812480146814;
const SWAP: f32 = 0.93426760093427;
// The whole picture is shown very slightly enlarged while the effect runs.
const ENLARGE: f32 = 1.01;

fn ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 14; i++) {
        let s = 0.5 * (lo + hi);
        let r = 1.0 - s;
        let bx = 3.0 * r * r * s * c.x + 3.0 * r * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let r = 1.0 - s;
    return 3.0 * r * r * s * c.y + 3.0 * r * s * s * c.w + s * s * s;
}

fn key(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return a; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

// How much of the red recolouring is shown (0 = none, 1 = full).
fn tint(t: f32) -> f32 {
    var keep: f32;
    if (t < 0.767434) {
        keep = key(t, 0.667334, 0.767434, 1.0, 0.0, vec4f(0.33333333, 0.0, 0.66666667, 1.0));
    } else if (t < SWAP) {
        keep = 0.0;
    } else {
        keep = key(t, SWAP, 1.201201, 0.0, 1.0, vec4f(0.33333333, 0.0, 0.66666667, 1.0));
    }
    return 1.0 - keep;
}

// Red component of a six-stop hue wheel (red, yellow, green, cyan, blue, magenta, red).
fn wheel_red(phase: f32) -> f32 {
    var reds = array<f32, 7>(1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0);
    for (var k = 0; k < 6; k++) {
        let a = f32(k) / 6.0;
        let b = f32(k + 1) / 6.0;
        if (a <= phase && phase <= b) {
            let f = clamp((phase - a) / (b - a + 0.001), 0.0, 1.0);
            return mix(reds[k], reds[k + 1], f);
        }
    }
    return 1.0;
}

// Bilinear read of the strip texture `sorted` at strip coordinates (u across, v down the rows).
fn strip_read(u: f32, v: f32) -> vec4f {
    let cols = i32(min(STRIP_COLS, u32(globals.size.x)));
    let rows = i32(globals.size.y);
    let fx = u * f32(cols) - 0.5;
    let fy = v * f32(rows) - 0.5;
    let x0 = i32(floor(fx));
    let y0 = i32(floor(fy));
    let wx = fx - floor(fx);
    let wy = fy - floor(fy);
    let xa = clamp(x0, 0, cols - 1);
    let xb = clamp(x0 + 1, 0, cols - 1);
    let ya = clamp(y0, 0, rows - 1);
    let yb = clamp(y0 + 1, 0, rows - 1);
    let top = mix(textureLoad(sorted, vec2i(xa, ya), 0), textureLoad(sorted, vec2i(xb, ya), 0), wx);
    let bottom = mix(textureLoad(sorted, vec2i(xa, yb), 0), textureLoad(sorted, vec2i(xb, yb), 0), wx);
    return mix(top, bottom, wy);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so the transition starts and finishes on the plain inputs.
    if (params.progress <= 0.0) {
        gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0));
        return;
    }
    if (params.progress >= 1.0) {
        gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0));
        return;
    }
    let t = mix(CLOCK_START, CLOCK_END, params.progress);
    let q = (uv - 0.5) / ENLARGE + 0.5;
    var base: vec3f;
    if (t >= SWAP) {
        base = textureSampleLevel(second, smp, q, 0.0).rgb;
    } else {
        base = textureSampleLevel(first, smp, q, 0.0).rgb;
    }
    // The strip holds the picture on its side: strip column = picture y, strip row = picture x.
    let s = strip_read(q.y, q.x);
    var c = mix(base, s.rgb, s.a);
    c = floor(clamp(c, vec3f(0.0), vec3f(1.0)) * 255.0 + 0.5) / 255.0;

    let amount = tint(t);
    if (amount > 0.0) {
        let mean = (c.r + c.g + c.b) / 3.0;
        var red = wheel_red(fract(max(max(c.r, c.g), c.b)));
        if (abs(mean - 1.0) < 0.001 || abs(mean) < 0.001) { red = 1.0; }
        c.r = mix(c.r, red, amount);
    }
    gpufx_write(id, vec4f(c, 1.0));
}
