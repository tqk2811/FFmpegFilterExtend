// Subject flash, step 2: threshold the bright parts and blur them sideways on a small grid.

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

const GLOW_RADIUS: f32 = 8.9333333;  // 13.4 px at 360 px, on a 240 px wide grid

fn threshold(t: f32) -> f32 {
    if (t < SWITCH_AT) { return ramp(t, 1.1, 1.266667, 1.0, 0.35); }
    return ramp(t, 1.6, 1.766667, 0.35, 1.0);
}

fn glow_grid() -> vec2f {
    if (globals.size.x <= 240.0) { return globals.size; }
    return floor(vec2f(240.0, globals.size.y / globals.size.x * 240.0));
}

fn bright(uv: vec2f, th: f32) -> vec3f {
    let c = textureSampleLevel(bent, smp, uv, 0.0).rgb;
    return smoothstep(vec3f(th - 0.075), vec3f(th + 0.075), c);
}

// The bright parts, sampled onto a small grid in the top-left corner and blurred across.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let grid = glow_grid();
    if (f32(id.x) >= grid.x || f32(id.y) >= grid.y) { gpufx_write(id, vec4f(0.0)); return; }
    let uv = (vec2f(id.xy) + vec2f(0.5)) / grid;
    let th = threshold(timeline_now());
    let spread = 2.0 * pow(GLOW_RADIUS / 2.4, 2.0);
    var acc = bright(uv, th);
    var total = 1.0;
    for (var i = 1.0; i <= GLOW_RADIUS; i += 1.0) {
        let w = exp(-i * i / spread);
        let o = vec2f(i / grid.x, 0.0);
        acc += (bright(uv + o, th) + bright(uv - o, th)) * w;
        total += 2.0 * w;
    }
    // At rest the threshold sits at 1 and still blooms near-white pixels (CapCut does the same), so fade the
    // halo in over the first and out over the last 7 % of progress to meet the plain clips at the ends.
    let p = clamp(params.progress, 0.0, 1.0);
    let lit_up = smoothstep(0.0, 0.07, p) * (1.0 - smoothstep(0.93, 1.0, p));
    gpufx_write(id, vec4f(acc / total * lit_up, 1.0));
}
