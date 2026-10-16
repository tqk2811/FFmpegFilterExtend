// The clips are two pictures of a film strip moving one frame along `direction`. The
// perforated bands and the gaps between pictures fade in and out with the motion, so the
// transition starts on the first clip and ends on the second exactly.
fn rounded_box(p: vec2f, half_size: vec2f, r: f32) -> f32 {
    let d = abs(p) - half_size + r;
    return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0) - r;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    if (p <= 0.0) { gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0)); return; }
    if (p >= 1.0) { gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0)); return; }
    let horizontal = params.direction < 2;
    // Moving right or down: measure from the far edge so the strip runs the other way.
    let sign = select(1.0, -1.0, params.direction == 1 || params.direction == 3);
    // a: along the motion, b: across it, both 0..1 in frame units.
    var a = uv.x;
    var b = uv.y;
    var aspect = globals.size.x / globals.size.y; // length along / across the motion
    if (!horizontal) { a = uv.y; b = uv.x; aspect = 1.0 / aspect; }
    let t = smoothstep(0.0, 1.0, p);
    let env = smoothstep(0.0, 0.2, p) * smoothstep(1.0, 0.8, p);
    let band = params.strip * env;
    let gap = params.gap * env;
    // Position on the strip: picture k covers [k, k+1); the first is k = 0.
    let s = select(a, 1.0 - a, sign < 0.0) + t;
    let k = floor(s);
    let f = s - k;                     // 0..1 inside the picture cell, along the motion
    let a_in = select(f, 1.0 - f, sign < 0.0);
    let half_gap = 0.5 * gap;
    let in_window = a_in >= half_gap && a_in <= 1.0 - half_gap && b >= band && b <= 1.0 - band;
    if (in_window && (k == 0.0 || k == 1.0)) {
        // The picture fills its window.
        var q = vec2f((a_in - half_gap) / (1.0 - gap), (b - band) / (1.0 - 2.0 * band));
        if (!horizontal) { q = q.yx; }
        let c = select(textureSampleLevel(first, smp, q, 0.0), textureSampleLevel(second, smp, q, 0.0), k == 1.0);
        gpufx_write(id, c);
        return;
    }
    // Film, with perforations in the bands. Units: frame heights across the motion.
    var col = params.film_color;
    if (b < band || b > 1.0 - band) {
        let n = f32(max(params.holes, 1));
        let pitch = aspect / n;                     // along the motion, across-units
        let along = s * aspect;
        let local = vec2f(along - (floor(along / pitch) + 0.5) * pitch, select(b, 1.0 - b, b > 0.5) - 0.5 * band);
        let hole = rounded_box(local, vec2f(0.3 * pitch, 0.25 * band), 0.08 * band);
        if (hole < 0.0) { col = params.hole_color; }
    }
    gpufx_write(id, col);
}
