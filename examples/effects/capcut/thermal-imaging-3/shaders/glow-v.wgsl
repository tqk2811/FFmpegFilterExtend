// Thermal Imaging 3, pass 3: vertical half of the per-channel glow spread.

const GRID: f32 = 240.0;
const WIDTH: vec3f = vec3f(0.0, 34.8, 357.6);
const STEP: f32 = 11.92;

fn jitter(a: f32, b: f32) -> f32 {
    var f = fract(vec2f(a, b) * 13.517);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y) - 0.5;
}

fn tap(q: vec2f, cells: vec2f) -> vec3f {
    // Grid position to texture position, kept half a texel inside the grid corner.
    let cell = clamp(q * cells, vec2f(0.5), cells - 0.5);
    return textureSampleLevel(glow_h, smp, cell / globals.size, 0.0).rgb;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    // The grid keeps the frame's aspect ratio, so its height is GRID * h / w rows.
    let grid = min(GRID, globals.size.x);
    let cells = vec2f(grid, max(floor(grid * globals.size.y / globals.size.x), 1.0));
    if (f32(id.x) >= cells.x || f32(id.y) >= cells.y) { gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0)); return; }
    let uv = (vec2f(id.xy) + 0.5) / cells;
    let py = 1.0 / cells.y;
    let spread = max(2.0 * (WIDTH / 2.4) * (WIDTH / 2.4), vec3f(1e-6));
    var sum = tap(uv, cells);
    var total = vec3f(1.0);
    var d = 1.0;
    for (var i = 0; i < 11; i++) {
        let w = select(vec3f(0.0), exp(-vec3f(d * d) / spread), WIDTH >= vec3f(d));
        let down = uv + vec2f(0.0, py * (d + STEP * jitter(d + uv.x + 0.223, d * uv.y)));
        let up = uv - vec2f(0.0, py * (d + STEP * jitter(d + uv.x + 0.569, d * uv.y)));
        sum += (tap(down, cells) + tap(up, cells)) * w;
        total += 2.0 * w;
        d += STEP;
    }
    gpufx_write(id, vec4f(sum / total, 1.0));
}
