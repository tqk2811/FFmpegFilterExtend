// Golden Sand glow, round 1: blur the bright-passed band along x on a coarse grid.

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn ease(x: f32, c: vec4f) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        let dx = 3.0 * inv * inv * c.x + 6.0 * inv * s * (c.z - c.x) + 3.0 * s * s * (1.0 - c.z);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Value going from `a` to `b` between times t0 and t1 along the easing curve `c`; `v` outside.
fn key(v: f32, t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    if (t < t0) { return v; }
    if (t >= t1) { return b; }
    return mix(a, b, ease((t - t0) / (t1 - t0), c));
}

const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);
const SPAN: f32 = 2.0;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// At the ends the last pass shows the plain clips, so the passes before it have nothing to do.
fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }

fn grid(shrink: f32) -> vec2f {
    return max(floor(globals.size * shrink), vec2f(1.0));
}

// Texel `j` of the coarse grid `cells`, as a uv of the full-size texture it is read from.
fn cell_uv(cells: vec2f, j: vec2f) -> vec2f {
    return (clamp(j, vec2f(0.0), cells - 1.0) + 0.5) / cells;
}

// Point `p` (in texels) of a coarse grid stored in the top-left corner of a texture, as a uv of that texture.
fn corner_uv(cells: vec2f, p: vec2f) -> vec2f {
    return clamp(p, vec2f(0.5), cells - 0.5) / globals.size;
}

const GLOW_GAMMA: f32 = 2.0;
const GLOW_THRESHOLD: f32 = 0.22;
const GAUSS0: f32 = 1.0;

// Bright-pass of the band layer: channels under the threshold drop out, the rest goes to gamma space.
fn bright_pass(c: vec4f) -> vec4f {
    let keep = select(vec3f(0.0), c.rgb, c.rgb >= vec3f(GLOW_THRESHOLD));
    return pow(vec4f(keep, c.a), vec4f(GLOW_GAMMA));
}

// Bilinear read of `band` sampled at the centres of the coarse grid `cells` (clamped edges).
fn cells_band(uv: vec2f, cells: vec2f) -> vec4f {
    let p = uv * cells - 0.5;
    let j = floor(p);
    let w = p - j;
    let a = textureSampleLevel(band, smp, cell_uv(cells, j), 0.0);
    let b = textureSampleLevel(band, smp, cell_uv(cells, j + vec2f(1.0, 0.0)), 0.0);
    let c = textureSampleLevel(band, smp, cell_uv(cells, j + vec2f(0.0, 1.0)), 0.0);
    let d = textureSampleLevel(band, smp, cell_uv(cells, j + vec2f(1.0)), 0.0);
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

@compute @workgroup_size(8, 8)
fn blur_x_1(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let cells = grid(0.05);
    // Only the texels of the coarse grid are worked out; they fill the top-left corner.
    if (f32(id.x) >= cells.x || f32(id.y) >= cells.y) { return; }
    let uv = (vec2f(id.xy) + 0.5) / cells;
    let longest = max(globals.size.x, globals.size.y);
    // One step along the axis, in uv, scaled so a step is the same length in x and y.
    let step = vec2f(1.0, 0.0) * longest / globals.size * 1.043478 / longest;
    var sum = pow(bright_pass(cells_band(uv, cells)).rgb, vec3f(GLOW_GAMMA)) * GAUSS0;
    var total = GAUSS0;
    for (var k = 1; k < 3; k++) {
        let x = f32(k) / 3.6 * 15.0;
        let w = exp(-x * x / 32.0);
        let o = step * f32(k);
        sum += (pow(bright_pass(cells_band(uv + o, cells)).rgb, vec3f(GLOW_GAMMA)) + pow(bright_pass(cells_band(uv - o, cells)).rgb, vec3f(GLOW_GAMMA))) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(pow(sum / total, vec3f(1.0 / GLOW_GAMMA)), 1.0));
}
