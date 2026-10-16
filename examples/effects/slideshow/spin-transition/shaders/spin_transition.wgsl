const PI: f32 = 3.14159265;

// One clip rotated by `angle` and scaled by `scale` around the center (pixel-correct),
// the background color outside it.
fn spun(use_second: bool, uv: vec2f, angle: f32, scale: f32) -> vec4f {
    let bg = vec4f(params.color.rgb, 1.0);
    if (scale <= 1e-4) { return bg; }
    let size = globals.size.xy;
    let p = (uv - 0.5) * size;
    let c = cos(angle);
    let s = sin(angle);
    let q = vec2f(c * p.x + s * p.y, -s * p.x + c * p.y) / scale;
    let src = q / size + 0.5;
    if (any(src < vec2f(0.0)) || any(src > vec2f(1.0))) { return bg; }
    if (use_second) { return textureSampleLevel(second, smp, src, 0.0); }
    return textureSampleLevel(first, smp, src, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    // First half: the first clip spins out; second half: the second clip spins in, still
    // turning the same way. q runs 0 -> 1 -> 0 over the transition.
    let use_second = p >= 0.5;
    let q = select(p * 2.0, (1.0 - p) * 2.0, use_second);
    // Whole half turns only: the first clip ends at +turns and the second starts at -turns,
    // the same angle only when 2 * turns is a whole number (and then p = 0 and 1 stay at 0).
    let turns = round(max(params.turns, 0.0) * 2.0) * 0.5;
    let turn = q * turns * 2.0 * PI;
    let angle = select(turn, -turn, use_second);
    let scale = 1.0 - clamp(params.zoom, 0.0, 1.0) * q;
    // Motion blur: average samples spread along the angle; the spread grows with the speed
    // of the phase and vanishes at both ends so they show the clips exactly.
    let span = q * turns * PI * 0.25;
    let n = select(max(params.blur, 1), 1, span <= 0.0);
    let steps = f32(max(n - 1, 1));
    var sum = vec4f(0.0);
    for (var k = 0; k < n; k++) {
        let off = select(0.0, span * (f32(k) / steps - 0.5), n > 1);
        sum += spun(use_second, uv, angle + off, scale);
    }
    gpufx_write(id, sum / f32(n));
}
