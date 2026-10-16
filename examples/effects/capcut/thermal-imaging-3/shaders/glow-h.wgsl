// Thermal Imaging 3, pass 2: pick the hot parts of the picture and spread them sideways, each channel by its own width.
//
// The glow lives on a grid GRID texels wide, stored in the top-left corner of the target. Red is not spread at all, green a little and
// blue a lot; taps are STEP grid texels apart and nudged by a small per-pixel jitter.

const GRID: f32 = 240.0;
const WIDTH: vec3f = vec3f(0.0, 34.8, 357.6); // grid texels per channel
const STEP: f32 = 11.92;                       // widest width / 30; only 11 taps are taken
const LIFT: f32 = 0.15;
const CUTS: vec3f = vec3f(0.37, 0.566078, 1.37);

fn over(c: f32, cut: f32) -> f32 {
    if (c <= cut) { return 0.0; }
    return (c - cut) / (1.0 - cut);
}

fn hot(q: vec2f) -> vec3f {
    let c = mix(textureSampleLevel(scene, smp, clamp(q, vec2f(0.0), vec2f(1.0)), 0.0).rgb, vec3f(1.0), LIFT);
    let w = over(c.r, CUTS.r) + over(c.g, CUTS.g) + over(c.b, CUTS.b);
    return c * (w / max(c.r + c.g + c.b, 1e-6));
}

fn jitter(a: f32, b: f32) -> f32 {
    var f = fract(vec2f(a, b) * 13.517);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y) - 0.5;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    // Worked out on the small grid only: cell (x, y) sits in the top-left corner of the target.
    let grid = min(GRID, globals.size.x);
    let cells = vec2f(grid, max(floor(grid * globals.size.y / globals.size.x), 1.0));
    if (f32(id.x) >= cells.x || f32(id.y) >= cells.y) { gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0)); return; }
    let uv = (vec2f(id.xy) + 0.5) / cells;
    let px = 1.0 / grid;
    let spread = max(2.0 * (WIDTH / 2.4) * (WIDTH / 2.4), vec3f(1e-6));
    var sum = hot(uv);
    var total = vec3f(1.0);
    var d = 1.0;
    for (var i = 0; i < 11; i++) {
        let w = select(vec3f(0.0), exp(-vec3f(d * d) / spread), WIDTH >= vec3f(d));
        let right = uv + vec2f(px * (d + STEP * jitter(d + uv.x + 0.199, d * uv.y)), 0.0);
        let left = uv - vec2f(px * (d + STEP * jitter(d + uv.x + 0.677, d * uv.y)), 0.0);
        sum += (hot(right) + hot(left)) * w;
        total += 2.0 * w;
        d += STEP;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
