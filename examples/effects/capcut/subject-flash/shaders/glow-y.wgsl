// Subject flash, step 3: finish the glow blur vertically.

const SPAN: f32 = 2.866657;
const SWITCH_AT: f32 = 1.433333;
const EASE_IO = vec4f(0.3333333, 0.0, 0.6666667, 1.0);

fn timeline_now() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

// Cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1), x solved by bisection.
fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(e.x, e.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(e.y, e.w, 0.5 * (lo + hi));
}

// One eased ramp from v0 (before t0) to v1 (after t1).
fn ramp(t: f32, t0: f32, t1: f32, v0: f32, v1: f32) -> f32 {
    if (t < t0) { return v0; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(EASE_IO, (t - t0) / (t1 - t0)));
}

const GLOW_RADIUS: f32 = 8.9333333;

fn glow_grid() -> vec2f {
    if (globals.size.x <= 240.0) { return globals.size; }
    return floor(vec2f(240.0, globals.size.y / globals.size.x * 240.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let grid = vec2i(glow_grid());
    let p = vec2i(id.xy);
    if (p.x >= grid.x || p.y >= grid.y) { gpufx_write(id, vec4f(0.0)); return; }
    let spread = 2.0 * pow(GLOW_RADIUS / 2.4, 2.0);
    var acc = textureLoad(glow_x, p, 0).rgb;
    var total = 1.0;
    for (var i = 1; f32(i) <= GLOW_RADIUS; i++) {
        let w = exp(-f32(i * i) / spread);
        let above = textureLoad(glow_x, vec2i(p.x, max(p.y - i, 0)), 0).rgb;
        let below = textureLoad(glow_x, vec2i(p.x, min(p.y + i, grid.y - 1)), 0).rgb;
        acc += (above + below) * w;
        total += 2.0 * w;
    }
    gpufx_write(id, vec4f(acc / total, 1.0));
}
