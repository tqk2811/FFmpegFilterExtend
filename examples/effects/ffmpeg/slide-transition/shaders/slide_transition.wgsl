// True when uv lies inside the frame.
fn inside(uv: vec2f) -> bool {
    return all(uv >= vec2f(0.0)) && all(uv <= vec2f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    var dir = vec2f(-1.0, 0.0);
    if (params.direction == 1) { dir = vec2f(1.0, 0.0); }
    if (params.direction == 2) { dir = vec2f(0.0, -1.0); }
    if (params.direction == 3) { dir = vec2f(0.0, 1.0); }
    let t = smoothstep(0.0, 1.0, params.progress);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    let bg = vec4f(params.color.rgb, 1.0);
    switch params.mode {
        case 1: {
            // Cover: the second clip slides in over the still first one.
            let b_uv = uv - dir * t + dir;
            gpufx_write(id, select(a, textureSampleLevel(second, smp, b_uv, 0.0), inside(b_uv)));
        }
        case 2: {
            // Uncover: the first clip slides out and reveals the still second one.
            let a_uv = uv - dir * t;
            gpufx_write(id, select(b, textureSampleLevel(first, smp, a_uv, 0.0), inside(a_uv)));
        }
        case 3: {
            // Push through color: the first clip is pushed out of the frame, then the second one in;
            // the background color shows in between.
            if (t < 0.5) {
                let a_uv = uv - dir * (t * 2.0);
                gpufx_write(id, select(bg, textureSampleLevel(first, smp, a_uv, 0.0), inside(a_uv)));
            } else {
                let b_uv = uv - dir * (t * 2.0 - 1.0) + dir;
                gpufx_write(id, select(bg, textureSampleLevel(second, smp, b_uv, 0.0), inside(b_uv)));
            }
        }
        default: {
            // Push: the first clip moves along dir; the second follows one frame behind.
            let a_uv = uv - dir * t;
            let b_uv = a_uv + dir;
            if (inside(a_uv)) {
                gpufx_write(id, textureSampleLevel(first, smp, a_uv, 0.0));
            } else {
                gpufx_write(id, textureSampleLevel(second, smp, b_uv, 0.0));
            }
        }
    }
}
