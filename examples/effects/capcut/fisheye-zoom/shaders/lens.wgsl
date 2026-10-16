// Fisheye zoom, step 1: squeeze the first clip into a shrinking fisheye disc (transparent outside it).

// CSS-like cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1), solved for x by bisection.
fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(e: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(e.x, e.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(e.y, e.w, 0.5 * (lo + hi));
}

// Disc size: 500 shrinking to 0 by 83 % of the transition.
fn disc_size(t: f32) -> f32 {
    return mix(500.0, 0.0, ease(vec4f(0.3333333, 0.0, 0.6666667, 1.0), clamp(t / 0.833333, 0.0, 1.0)));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let aspect = globals.size.x / globals.size.y;
    // The disc is scaled up on wide frames.
    let size = disc_size(clamp(params.progress, 0.0, 1.0)) * pow(1.6, aspect - 1.0);
    var d = uv - vec2f(0.5);
    d.x *= aspect;
    let dist = length(d);
    let edge = size * 0.007;
    let inside = smoothstep(edge + 0.001, edge - 0.001, dist);
    if (inside <= 0.0 || size <= 0.0) { gpufx_write(id, vec4f(0.0)); return; }
    // Barrel lens with strength 100: points near the rim are pulled toward the centre.
    let bent = dist * (1.0 - 100.0 * 203.0875 / (size * size) * dist * dist);
    var q = vec2f(0.0);
    if (dist > 0.0) { q = d / dist * bent; }
    q.x /= aspect;
    q += vec2f(0.5);
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { gpufx_write(id, vec4f(0.0)); return; }
    let c = textureSampleLevel(first, smp, q, 0.0);
    // Stored premultiplied, so the zoom blur can average it directly.
    gpufx_write(id, vec4f(c.rgb * inside, inside));
}
