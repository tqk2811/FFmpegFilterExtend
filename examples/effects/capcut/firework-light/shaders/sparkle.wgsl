// Firework Light, pass 1: a burst of warm sparkles screened over the clip of the moment (hard cut at mid-time).

// Animation time (seconds) covered by progress 0..1; the clips swap halfway.
const SPAN: f32 = 2.0;
// Time step between two rows of the glow table below.
const TABLE_STEP: f32 = 0.13333333;
// Sparkle colour (warm white).
const TINT: vec3f = vec3f(1.0, 0.97, 0.9);
// Sparkle grid: cells across the short side of the frame.
const CELLS: f32 = 20.0;

// Average glow of the burst, six horizontal bands from top to bottom, sampled every TABLE_STEP
// seconds from t = 0. The burst wells up from the bottom, floods the frame and thins out.
const GLOW = array<array<f32, 6>, 15>(
    array<f32, 6>(0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
    array<f32, 6>(0.0, 0.0, 0.0, 0.07, 0.41, 0.69),
    array<f32, 6>(0.0, 0.09, 0.54, 0.91, 0.97, 0.97),
    array<f32, 6>(0.29, 0.73, 0.9, 0.97, 0.97, 0.88),
    array<f32, 6>(0.67, 0.88, 0.95, 0.96, 0.92, 0.72),
    array<f32, 6>(0.49, 0.62, 0.76, 0.68, 0.6, 0.46),
    array<f32, 6>(0.28, 0.55, 0.78, 0.73, 0.59, 0.4),
    array<f32, 6>(0.32, 0.61, 0.76, 0.72, 0.61, 0.51),
    array<f32, 6>(0.23, 0.34, 0.53, 0.62, 0.5, 0.41),
    array<f32, 6>(0.12, 0.18, 0.26, 0.34, 0.36, 0.31),
    array<f32, 6>(0.09, 0.1, 0.12, 0.21, 0.26, 0.23),
    array<f32, 6>(0.21, 0.29, 0.36, 0.4, 0.45, 0.49),
    array<f32, 6>(0.02, 0.04, 0.09, 0.11, 0.15, 0.15),
    array<f32, 6>(0.0, 0.02, 0.07, 0.08, 0.1, 0.17),
    array<f32, 6>(0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
);

fn band(row: i32, slot: i32) -> f32 {
    var table = GLOW;
    return table[clamp(slot, 0, 14)][clamp(row, 0, 5)];
}

// Glow at height y (0 top, 1 bottom) and time t, interpolated between bands and table rows.
fn glow_at(y: f32, t: f32) -> f32 {
    let fy = clamp(y * 6.0 - 0.5, 0.0, 5.0);
    let r0 = i32(floor(fy));
    let ry = smoothstep(0.0, 1.0, fy - f32(r0));
    let ft = clamp(t / TABLE_STEP, 0.0, 14.0);
    let s0 = i32(floor(ft));
    let st = ft - f32(s0);
    let a = mix(band(r0, s0), band(r0 + 1, s0), ry);
    let b = mix(band(r0, s0 + 1), band(r0 + 1, s0 + 1), ry);
    return mix(a, b, st);
}

fn hash3(p: vec2f) -> vec3f {
    var q = vec3f(dot(p, vec2f(127.1, 311.7)), dot(p, vec2f(269.5, 183.3)), dot(p, vec2f(419.2, 371.9)));
    return fract(sin(q) * 43758.5453);
}

// Field of twinkling sparkle points, about 0.5 on average.
fn sparkles(pos: vec2f, t: f32) -> f32 {
    // The whole field drifts slowly upwards.
    let p = (pos + vec2f(0.0, t * 0.12)) * CELLS;
    let cell = floor(p);
    var sum = 0.0;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let c = cell + vec2f(f32(i), f32(j));
            let r = hash3(c);
            let centre = c + 0.2 + 0.6 * r.xy;
            let d = length(p - centre);
            let size = mix(0.3, 0.9, r.z * r.z);
            let flicker = 0.6 + 0.4 * sin(t * 9.0 + r.x * 40.0);
            sum += exp(-d * d / (size * size)) * flicker * (0.6 + 1.6 * r.y);
        }
    }
    return sum;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = params.progress * SPAN;
    var base: vec4f;
    if (t <= 1.0) {
        base = textureSampleLevel(first, smp, uv, 0.0);
    } else {
        base = textureSampleLevel(second, smp, uv, 0.0);
    }
    // The burst wells up a little ahead of the clock during the first half second.
    let ts = t + 0.03 * smoothstep(0.0, 0.15, t) * (1.0 - smoothstep(0.3, 0.5, t));
    var g = glow_at(uv.y, ts);
    // The opening burst is a dome centred on the bottom edge.
    let early = 1.0 - smoothstep(0.2, 0.45, ts);
    g *= mix(1.0, exp(-pow((uv.x - 0.5) / 0.6, 2.0)), early);
    let pos = (uv - 0.5) * globals.size / min(globals.size.x, globals.size.y);
    // The opening flare is a smooth haze; later dense areas saturate to a flat white and
    // sparse ones break up into points.
    let grain = mix(1.7, 0.45 + 1.1 * sparkles(pos, ts), smoothstep(0.15, 0.35, ts));
    let field = g * grain;
    let light = clamp(field, 0.0, 1.0) * TINT;
    let screened = 1.0 - (1.0 - base.rgb) * (1.0 - light);
    gpufx_write(id, vec4f(screened, 1.0));
}
