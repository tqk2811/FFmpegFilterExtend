// Pixel Vibe, pass 2: zoom blur smeared between the previous and the current punch-in scale.

const FRAME: f32 = 0.0333333; // the "previous frame" the blur smears from, in progress units

fn ease(u: f32) -> f32 {
    let v = clamp(u, 0.0, 1.0);
    return v * v * (3.0 - 2.0 * v);
}

// Punch-in: 1 -> 1.5 by a third, back to 1 at the end.
fn punch(t: f32) -> f32 {
    if (t < 0.333333) { return mix(1.0, 1.5, ease(t / 0.333333)); }
    return mix(1.5, 1.0, ease((t - 0.333333) / 0.666667));
}

fn grain(a: f32, b: f32) -> f32 {
    var f = fract(vec2f(a, b) * 13.517);
    f += dot(f, f.yx + 22.541);
    return fract((f.x + f.y) * f.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let before = punch(t - FRAME);
    let now = punch(t);
    // Six control points spread over blend weights 0.75 .. 1.25 between the two scales.
    var pts: array<vec2f, 6>;
    for (var i = 0; i < 6; i++) {
        let w = 0.75 + 0.1 * f32(i);
        pts[i] = (uv - 0.5) / mix(before, now, w) + 0.5;
    }
    let taps = floor(12.0 + 12.0 * smoothstep(0.0, 0.2, length(pts[5] - pts[0])));
    let gv = vec2f(uv.x, 1.0 - uv.y);
    var sum = vec3f(0.0);
    for (var k = 0.0; k < taps; k += 1.0) {
        let u = k / (taps - 1.0) + (grain(k + gv.x, k * gv.y) - 0.5) / taps;
        let seg = clamp(floor(u * 5.0), 0.0, 4.0);
        let n = u32(seg);
        let s = mix(pts[n], pts[n + 1u], u * 5.0 - seg);
        if (all(s >= vec2f(0.0)) && all(s <= vec2f(1.0))) {
            sum += textureSampleLevel(lit, smp, s, 0.0).rgb;
        }
    }
    gpufx_write(id, vec4f(sum / taps, 1.0));
}
