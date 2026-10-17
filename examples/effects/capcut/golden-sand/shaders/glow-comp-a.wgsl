// Golden Sand glow: screen each round's blur over the previous round.

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

fn screen3(a: vec3f, b: vec3f) -> vec3f { return 1.0 - (1.0 - a) * (1.0 - b); }

// Lays the blurred copy over the round's input with a screen blend, then applies the exposure.
fn merge(src: vec4f, halo: vec3f, weight: f32, gain: f32) -> vec4f {
    let a = vec4f(pow(src.rgb, vec3f(GLOW_GAMMA)), src.a);
    let b = vec4f(pow(halo, vec3f(GLOW_GAMMA)), 1.0);
    let ua = a.rgb / max(a.a, 0.001);
    let ub = b.rgb / max(a.a, 0.001);
    let lit = screen3(ua, ub) * weight + ua * (1.0 - weight);
    let rgb = a.rgb * (1.0 - b.a) + b.rgb * (1.0 - a.a) + lit * (a.a * b.a);
    let alpha = a.a + b.a * (1.0 - a.a);
    let o = vec4f(rgb, alpha) * gain;
    return clamp(vec4f(pow(max(o.rgb, vec3f(0.0)), vec3f(1.0 / GLOW_GAMMA)), o.a), vec4f(0.0), vec4f(1.0));
}

// Bilinear read of the coarse grid `cells` stored in the top-left corner of `g_y` (clamped edges).
fn corner_g_y(uv: vec2f, cells: vec2f) -> vec4f {
    return textureSampleLevel(g_y, smp, corner_uv(cells, uv * cells), 0.0);
}

@compute @workgroup_size(8, 8)
fn comp_3_upper(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    let t = clock();
    let gain = key(key(key(0.0, t, 0.0, 0.666667, 0.0, 0.9, vec4f(0.2, 0.0, 0.8, 1.0)), t, 0.666667, 1.133333, 0.9, 0.9, LINEAR), t, 1.133333, 2.0, 0.9, 0.5, vec4f(0.422435, 0.0, 0.772559, 1.0));
    let halo = corner_g_y(uv, grid(0.025)).rgb;
    gpufx_write(id, merge(textureSampleLevel(g_a, smp, uv, 0.0), halo, 0.4584373, gain));
}

@compute @workgroup_size(8, 8)
fn comp_5_upper(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    let t = clock();
    let gain = key(key(key(0.0, t, 0.0, 0.666667, 0.0, 0.9, vec4f(0.2, 0.0, 0.8, 1.0)), t, 0.666667, 1.133333, 0.9, 0.9, LINEAR), t, 1.133333, 2.0, 0.9, 0.5, vec4f(0.422435, 0.0, 0.772559, 1.0));
    let halo = corner_g_y(uv, grid(0.025)).rgb;
    gpufx_write(id, merge(textureSampleLevel(g_a, smp, uv, 0.0), halo, 0.2750624, gain));
}

@compute @workgroup_size(8, 8)
fn comp_7_upper(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    let t = clock();
    let gain = key(key(key(0.0, t, 0.0, 0.666667, 0.0, 0.9, vec4f(0.2, 0.0, 0.8, 1.0)), t, 0.666667, 1.133333, 0.9, 0.9, LINEAR), t, 1.133333, 2.0, 0.9, 0.5, vec4f(0.422435, 0.0, 0.772559, 1.0));
    let halo = corner_g_y(uv, grid(0.025)).rgb;
    gpufx_write(id, merge(textureSampleLevel(g_a, smp, uv, 0.0), halo, 0.1964731, gain));
}

@compute @workgroup_size(8, 8)
fn comp_3_lower(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    let t = clock();
    let gain = key(key(key(0.0, t, 0.0, 0.666667, 0.0, 0.84, vec4f(0.2, 0.0, 0.8, 1.0)), t, 0.666667, 1.133333, 0.84, 0.84, LINEAR), t, 1.133333, 2.0, 0.84, 1.04, vec4f(0.511348, 0.0, 0.988462, 1.0));
    let halo = corner_g_y(uv, grid(0.025)).rgb;
    gpufx_write(id, merge(textureSampleLevel(g_a, smp, uv, 0.0), halo, 0.4584373, gain));
}

@compute @workgroup_size(8, 8)
fn comp_5_lower(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    let t = clock();
    let gain = key(key(key(0.0, t, 0.0, 0.666667, 0.0, 0.84, vec4f(0.2, 0.0, 0.8, 1.0)), t, 0.666667, 1.133333, 0.84, 0.84, LINEAR), t, 1.133333, 2.0, 0.84, 1.04, vec4f(0.511348, 0.0, 0.988462, 1.0));
    let halo = corner_g_y(uv, grid(0.025)).rgb;
    gpufx_write(id, merge(textureSampleLevel(g_a, smp, uv, 0.0), halo, 0.2750624, gain));
}

@compute @workgroup_size(8, 8)
fn comp_7_lower(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    let t = clock();
    let gain = key(key(key(0.0, t, 0.0, 0.666667, 0.0, 0.84, vec4f(0.2, 0.0, 0.8, 1.0)), t, 0.666667, 1.133333, 0.84, 0.84, LINEAR), t, 1.133333, 2.0, 0.84, 1.04, vec4f(0.511348, 0.0, 0.988462, 1.0));
    let halo = corner_g_y(uv, grid(0.025)).rgb;
    gpufx_write(id, merge(textureSampleLevel(g_a, smp, uv, 0.0), halo, 0.1964731, gain));
}
