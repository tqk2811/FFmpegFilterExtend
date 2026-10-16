// Zoom out of the first clip under a radial blur, then zoom in on the second one.

// Quintic ease: slow start, fast middle, slow finish.
fn smooth_quint(x: f32) -> f32 {
    if (x < 0.5) { return 16.0 * pow(x, 5.0); }
    let r = x - 1.0;
    return 1.0 + 16.0 * r * r * r * r * r;
}

// Fold coordinates that leave [0, 1] back inside, so the edges mirror instead of clamping.
fn fold(p: vec2f) -> vec2f {
    let a = abs(p);
    return select(a, 2.0 - a, a > vec2f(1.0));
}

fn fetch(from_second: bool, p: vec2f) -> vec3f {
    if (from_second) {
        return textureSampleLevel(second, smp, p, 0.0).rgb;
    }
    return textureSampleLevel(first, smp, p, 0.0).rgb;
}

// Average 21 samples spread along the line through the frame centre; the spread grows
// with `strength` and with the distance from the centre.
fn zoom_blur(from_second: bool, p: vec2f, strength: f32, spacing: f32) -> vec3f {
    let reach = (p - 0.5) * 2.0 * strength * spacing;
    var acc = vec3f(0.0);
    for (var k = -10; k <= 10; k++) {
        acc += fetch(from_second, fold(p + reach * f32(k)));
    }
    return acc / 21.0;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let spacing = 5.0 / globals.size.x;
    let e = smooth_quint(clamp(params.progress, 0.0, 1.0));
    // First half: the view widens from 1x to 1.5x (zooming out). Second half: it narrows
    // from 0.5x back to 1x, so the second clip starts magnified and settles.
    var zoom = e;
    if (e < 0.499999) { zoom = 1.0 + e; }
    let p = 0.5 + (uv - 0.5) * zoom;
    var color: vec3f;
    // CapCut hands this transition the second clip from the midpoint on.
    if (e < 0.5) {
        color = zoom_blur(false, p, e, spacing);
    } else {
        color = zoom_blur(true, p, 1.0 - e, spacing);
    }
    gpufx_write(id, vec4f(color, 1.0));
}
