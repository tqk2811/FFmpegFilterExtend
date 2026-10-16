// Four phases of equal length, as in box_in_horizontal.sh / box_in_vertical.sh:
// zoom out (the first clip shrinks into a centred box), slide out (that box leaves the
// frame), slide in (a box of the second clip comes in from the same side), zoom in (it
// grows to fill the frame). Motion is linear, like the script's overlay and zoompan.

// The clip drawn scaled by `scale` around the frame centre moved by `offset` (in frames),
// or the background outside it.
fn boxed(use_second: bool, uv: vec2f, scale: f32, offset: vec2f) -> vec4f {
    let q = (uv - 0.5 - offset) / scale + 0.5;
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return params.color; }
    if (use_second) { return textureSampleLevel(second, smp, q, 0.0); }
    return textureSampleLevel(first, smp, q, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // dir: where the second box moves as it comes in; the first box leaves along -dir.
    var dir = vec2f(-1.0, 0.0);
    if (params.direction == 1) { dir = vec2f(1.0, 0.0); }
    if (params.direction == 2) { dir = vec2f(0.0, -1.0); }
    if (params.direction == 3) { dir = vec2f(0.0, 1.0); }
    let p = params.progress;
    if (p <= 0.0) { gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0)); return; }
    if (p >= 1.0) { gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0)); return; }
    let box = clamp(params.box, 0.1, 1.0);
    let s = fract(p * 4.0);
    if (p < 0.25) {
        gpufx_write(id, boxed(false, uv, mix(1.0, box, s), vec2f(0.0)));
    } else if (p < 0.5) {
        gpufx_write(id, boxed(false, uv, box, -dir * s));
    } else if (p < 0.75) {
        gpufx_write(id, boxed(true, uv, box, -dir * (1.0 - s)));
    } else {
        gpufx_write(id, boxed(true, uv, mix(box, 1.0, s), vec2f(0.0)));
    }
}
