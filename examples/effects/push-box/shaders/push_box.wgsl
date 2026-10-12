// Phases, as in the slideshow scripts (zoom 1, hold 1/5, push 1/2, hold 1/5, zoom 1):
// the first clip shrinks into a box, waits, both boxes move one frame along `direction`,
// the box of the second clip waits, then grows to fill the frame.
const ZOOM: f32 = 1.0 / 2.9;
const HOLD: f32 = 0.2 / 2.9;
const PUSH: f32 = 0.5 / 2.9;

fn phase(p: f32, start: f32, len: f32) -> f32 {
    return smoothstep(0.0, 1.0, clamp((p - start) / len, 0.0, 1.0));
}

// The clip drawn scaled by `scale` around the frame centre moved by `offset` (in frames),
// or the background outside it.
fn boxed(tex: texture_2d<f32>, uv: vec2f, scale: f32, offset: vec2f) -> vec4f {
    let q = (uv - 0.5 - offset) / scale + 0.5;
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return params.color; }
    return textureSampleLevel(tex, smp, q, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    var dir = vec2f(-1.0, 0.0);
    if (params.direction == 1) { dir = vec2f(1.0, 0.0); }
    if (params.direction == 2) { dir = vec2f(0.0, -1.0); }
    if (params.direction == 3) { dir = vec2f(0.0, 1.0); }
    let p = params.progress;
    if (p <= 0.0) { gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0)); return; }
    if (p >= 1.0) { gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0)); return; }
    let shrink = phase(p, 0.0, ZOOM);
    let push = phase(p, ZOOM + HOLD, PUSH);
    let grow = phase(p, ZOOM + 2.0 * HOLD + PUSH, ZOOM);
    let box = clamp(params.box, 0.01, 1.0);
    if (push < 1.0) {
        let a = boxed(first, uv, mix(1.0, box, shrink), dir * push);
        // The second box only shows once it enters the frame.
        let b = boxed(second, uv, box, dir * (push - 1.0));
        let in_b = all(abs(uv - 0.5 - dir * (push - 1.0)) <= vec2f(0.5 * box));
        gpufx_write(id, select(a, b, in_b && push > 0.0));
    } else {
        gpufx_write(id, boxed(second, uv, mix(box, 1.0, grow), vec2f(0.0)));
    }
}
