// Pull away: the first clip splits along its middle and its halves slide off up and down, uncovering the second clip as two darkened, tilted panels that unfold flat.

const SPAN: f32 = 0.6;

fn curve(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

// Cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1).
fn ease(c: vec4f, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let mid = 0.5 * (lo + hi);
        if (curve(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return curve(c.y, c.w, 0.5 * (lo + hi));
}

fn seg(prev: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, c: vec4f) -> f32 {
    if (t < t0) { return prev; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(c, (t - t0) / (t1 - t0)));
}

// Perspective map of the unit square onto the quad p00 (u=0,v=0), p10, p01, p11; returns the 3x3 matrix.
fn square_to_quad(p00: vec2f, p10: vec2f, p01: vec2f, p11: vec2f) -> mat3x3f {
    let d1 = p10 - p11;
    let d2 = p01 - p11;
    let s = p00 - p10 + p11 - p01;
    let den = d1.x * d2.y - d2.x * d1.y;
    let g = (s.x * d2.y - d2.x * s.y) / den;
    let h = (d1.x * s.y - s.x * d1.y) / den;
    return mat3x3f(
        vec3f(p10.x - p00.x + g * p10.x, p10.y - p00.y + g * p10.y, g),
        vec3f(p01.x - p00.x + h * p01.x, p01.y - p00.y + h * p01.y, h),
        vec3f(p00.x, p00.y, 1.0));
}

fn inverse3(m: mat3x3f) -> mat3x3f {
    let a = m[0];
    let b = m[1];
    let c = m[2];
    let r0 = cross(b, c);
    let r1 = cross(c, a);
    let r2 = cross(a, b);
    let det = dot(a, r0);
    return transpose(mat3x3f(r0, r1, r2)) * (1.0 / det);
}

// Brightness curve: negative values darken towards black, positive ones lift the mids.
fn shade(c: vec3f, amount: f32) -> vec3f {
    var k = amount;
    if (k > 0.0 && k <= 0.7) { k = 0.3 * k; } else if (k > 0.7) { k = 0.6333 * k - 0.2333; }
    var base = c;
    var e: f32;
    if (k > 0.0) {
        e = 5.0 * k + 1.0;
    } else {
        base = c + vec3f(0.01 * k);
        e = 1.0 / (1.0 - 2.5 * k);
    }
    return clamp(1.0 - pow(max(1.0 - base, vec3f(0.0)), vec3f(e)), vec3f(0.0), vec3f(1.0));
}

// One half of the second clip, pinned so its edge at the seam is pulled in by `pinch`, then stretched vertically by `tall`
// about the middle of the frame. `upper` picks the top half or the bottom one.
fn panel(uv: vec2f, pinch: f32, tall: f32, upper: bool) -> vec4f {
    if (tall <= 1e-5) { return vec4f(0.0); }
    let q = vec2f(uv.x, (uv.y - 0.5) / tall + 0.5);
    var m: mat3x3f;
    if (!upper) {
        m = square_to_quad(vec2f(pinch, pinch), vec2f(1.0 - pinch, pinch), vec2f(0.0, 1.0), vec2f(1.0, 1.0));
    } else {
        m = square_to_quad(vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(pinch, 1.0 - pinch), vec2f(1.0 - pinch, 1.0 - pinch));
    }
    let h = inverse3(m) * vec3f(q, 1.0);
    let src = h.xy / h.z;
    if (any(src < vec2f(0.0)) || any(src > vec2f(1.0))) { return vec4f(0.0); }
    if (upper == (src.y >= 0.5)) { return vec4f(0.0); }
    return vec4f(textureSampleLevel(second, smp, src, 0.0).rgb, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let open = ease(vec4f(0.82, 0.03, 0.47, 1.0), t / SPAN);

    // Halves of the first clip sliding apart.
    let gap = 0.5 * open;
    if (uv.y < 0.5 - gap) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, vec2f(uv.x, uv.y + gap), 0.0).rgb, 1.0));
        return;
    }
    if (uv.y >= 0.5 + gap) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, vec2f(uv.x, uv.y - gap), 0.0).rgb, 1.0));
        return;
    }

    let pinch = (1.0 / 6.0) * (1.0 - open);
    var c = vec3f(0.0);
    // The top panel starts black, the bottom one only dimmed and briefly over-bright.
    let top = panel(uv, pinch, open, true);
    if (top.a > 0.0) {
        let dim = seg(-1.0, t, 0.0, SPAN, -1.0, 0.0, vec4f(0.42, 0.0, 0.48, 1.0));
        c = shade(top.rgb, dim);
    }
    let bottom = panel(uv, pinch, open, false);
    if (bottom.a > 0.0) {
        var lift = seg(-0.7, t, 0.0, 0.366667, -0.7, 0.12, vec4f(0.001078821, 0.0, 0.59609259, 1.0));
        lift = seg(lift, t, 0.366667, SPAN, 0.12, 0.0, vec4f(0.210691494, 0.0, 0.551191741, 1.0));
        c = shade(bottom.rgb, lift);
    }
    gpufx_write(id, vec4f(c, 1.0));
}
