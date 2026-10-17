// The first clip tips back and twists away as a card while the second clip swings round on a soft shadow and grows to fill the frame.

// Animation time (seconds) covered by progress 0..1.
const SPAN: f32 = 1.5;
// Horizontal field of view of the camera that looks at the first clip's card, in degrees.
const FOV_X: f32 = 39.6;

// Cubic Bezier through (x0,y0), (x1,y1), (x2,y2), (x3,y3): find the curve parameter whose
// x is `x` by halving the interval below 1/128, then return y there.
fn curve_at(x: f32, xs: vec4f, ys: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 8; i++) {
        let mid = (lo + hi) * 0.5;
        let m = 1.0 - mid;
        let bx = xs.x * m * m * m + 3.0 * xs.y * m * m * mid + 3.0 * xs.z * m * mid * mid + xs.w * mid * mid * mid;
        if (bx > x) { hi = mid; } else { lo = mid; }
    }
    let s = (lo + hi) * 0.5;
    let m = 1.0 - s;
    return ys.x * m * m * m + 3.0 * ys.y * m * m * s + 3.0 * ys.z * m * s * s + ys.w * s * s * s;
}

// One keyed segment: held at `a` before t0 and at `b` after t1, eased in between by the
// handles (hx1, hy1) and (hx2, hy2) given in absolute time / value.
fn seg(t: f32, t0: f32, t1: f32, a: f32, b: f32, h: vec4f) -> f32 {
    if (t <= t0) { return a; }
    if (t >= t1) { return b; }
    return curve_at(t, vec4f(t0, h.x, h.z, t1), vec4f(a, h.y, h.w, b));
}

// Standard normal cumulative shape, 0.5 * (1 + erf(x)), via a rational approximation.
fn soft_step(x: f32) -> f32 {
    let z = abs(x);
    let k = 1.0 / (1.0 + 0.3275911 * z);
    let poly = k * (0.254829592 + k * (-0.284496736 + k * (1.421413741 + k * (-1.453152027 + k * 1.061405429))));
    let e = 1.0 - poly * exp(-z * z);
    return 0.5 * (1.0 + sign(x) * e);
}

fn rot2(p: vec2f, deg: f32) -> vec2f {
    let a = radians(deg);
    let c = cos(a);
    let s = sin(a);
    return vec2f(c * p.x - s * p.y, s * p.x + c * p.y);
}

// Texture coordinates (y up) to the WGSL convention (y down).
fn flip(v: vec2f) -> vec2f {
    return vec2f(v.x, 1.0 - v.y);
}

fn inside(v: vec2f) -> bool {
    return all(v >= vec2f(0.0)) && all(v <= vec2f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends of the transition.
    if (params.progress <= 0.0) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    if (params.progress >= 1.0) {
        gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0));
        return;
    }

    let t = params.progress * SPAN;
    let size = globals.size;
    let w = size.x;
    let h = size.y;
    // Pixel position with the origin bottom-left, y up.
    let pix = vec2f(uv.x, 1.0 - uv.y) * size;

    // Shared spin of the whole rig (degrees, clockwise on screen).
    let spin = seg(t, 0.0, 1.5, 0.0, 180.0, vec4f(0.94269816, 0.0, 0.40322733, 180.0));

    // ---- First clip: a 3D card that drops, stretches and tips back about its x axis.
    var drop: f32;
    if (t < 0.46666667) {
        drop = seg(t, 0.0, 0.46666667, 0.0, 100.0, vec4f(0.14466667, 0.0, 0.23333333, 100.0));
    } else {
        drop = 100.0 - seg(t, 0.46666667, 1.5, 0.0, 320.0, vec4f(0.96266667, 0.0, 1.08666667, 320.0));
    }
    var tilt: f32;
    if (t < 0.46666667) {
        tilt = seg(t, 0.0, 0.46666667, 0.0, 73.5, vec4f(0.18749151, 0.0, 0.23235553, 69.72274498));
    } else {
        tilt = seg(t, 0.46666667, 1.5, 73.5, 94.0, vec4f(0.94779965, 80.62809335, 1.14234546, 94.0));
    }
    let stretch_x = seg(t, 0.0, 0.46666667, 100.0, 75.0, vec4f(0.294, 100.0, 0.34066667, 75.0)) / 100.0;
    var stretch_y = seg(t, 0.0, 0.46666667, 100.0, 228.0, vec4f(0.294, 100.0, 0.34066667, 228.0)) / 100.0;
    stretch_y = 1.0 + (stretch_y - 1.0) * max(w / h * 1.6, 1.0);
    let shade_a = seg(t, 0.0, 0.46666667, 0.0, 85.0, vec4f(0.22794201, 0.0, 0.3274853, 85.0)) / 100.0;

    // Camera at the origin looking down -z; the card's rest plane z = -focal fills the frame.
    let focal = (w * 0.5) / tan(radians(FOV_X * 0.5));
    let centred = pix - size * 0.5;
    // Undo the spin, the drop and the tilt to bring the view ray into the card's frame.
    let dir_xy = rot2(centred, spin);
    var org = vec3f(0.0, -(-drop / 1080.0 * h), focal);
    var dir = vec3f(dir_xy, -focal);
    let ta = radians(-tilt);
    let ca = cos(ta);
    let sa = sin(ta);
    org = vec3f(org.x, ca * org.y - sa * org.z, sa * org.y + ca * org.z);
    dir = vec3f(dir.x, ca * dir.y - sa * dir.z, sa * dir.y + ca * dir.z);
    var col = vec4f(0.0);
    if (abs(dir.z) > 1e-6) {
        let k = -org.z / dir.z;
        if (k > 0.0) {
            let hit = org.xy + dir.xy * k;
            let card = hit / (vec2f(stretch_x * w, stretch_y * h) * 0.5);
            let tc = (card + 1.0) * 0.5;
            if (inside(tc)) {
                let src = textureSampleLevel(first, smp, flip(tc), 0.0);
                // Dark gradient laid over the card, heavier towards its bottom edge.
                let shade = soft_step((1.0 - tc.y - 0.405) / 0.285) * shade_a;
                col = vec4f(src.rgb * (1.0 - shade), 1.0);
            }
        }
    }

    // ---- Second clip: a flat card hung below a pivot, upside down against the spin.
    let rise = seg(t, 0.46666667, 1.5, 0.0, 700.60003662, vec4f(1.08666667, 0.0, 1.097, 700.60003662));
    let lift = (160.60003662 - rise) / 1080.0;
    let grow = seg(t, 0.46666667, 1.5, 25.0, 100.0, vec4f(1.08666667, 25.0, 1.097, 100.0)) / 100.0;
    let dim_b = seg(t, 0.46666667, 1.33333333, 50.0, 0.0, vec4f(0.76425159, 50.0, 1.03946297, 0.0)) / 100.0;
    let wipe = seg(t, 0.13333333, 0.46666667, 75.0, 25.0, vec4f(0.23333333, 69.58333333, 0.28666667, 25.83333333)) / 100.0;

    // Screen pixel -> pivot frame (the spin), then into the card (offset, scale, half turn).
    let q = rot2(centred, spin);
    let qb = rot2((q + vec2f(0.0, lift * h)) / grow, 180.0) + vec2f(0.5 * w, 0.0);
    let tb = qb / size;
    var card_b = vec4f(0.0);
    // The card is cut by a straight edge sweeping down its frame from the top.
    if (inside(tb) && tb.y >= wipe * 2.0 - 0.5) {
        card_b = vec4f(textureSampleLevel(second, smp, flip(tb), 0.0).rgb * (1.0 - dim_b), 1.0);
    }

    // Soft dark bar under the second card's pivot, widening as the card grows.
    let bar_w = w;
    let bar_h = 194.0 * w / 997.0;
    let bar_sx = seg(t, 0.53333333, 1.5, 124.0, 125.0, vec4f(1.297, 124.0, 1.21, 125.0)) / 100.0 * 0.9;
    let bar_sy = seg(t, 0.53333333, 1.5, 48.0, 330.0, vec4f(1.297, 92.275878, 1.21, 318.93103)) / 100.0;
    var bar_a: f32;
    if (t < 0.83333333) {
        bar_a = seg(t, 0.53333333, 0.83333333, 0.0, 55.0, vec4f(0.58284323, 0.0, 0.70354486, 55.0));
    } else {
        bar_a = seg(t, 0.83333333, 1.5, 55.0, 0.0, vec4f(1.14876686, 55.0, 1.38820774, 35.36811310));
    }
    bar_a /= 100.0;
    let qs = rot2((q + vec2f(0.0, lift * h)) / grow, 180.0) + vec2f(0.5 * w, 0.0);
    let qbar = (qs - vec2f(w * 0.5, h * (1.0 - 1093.8 / 1080.0))) / vec2f(bar_sx, bar_sy) + vec2f(0.5 * bar_w, 0.5 * bar_h);
    let tbar = qbar / vec2f(bar_w, bar_h);
    var bar = 0.0;
    if (inside(tbar)) {
        let bx = soft_step((tbar.x - 0.042) / 0.0235) - soft_step((tbar.x - 0.958) / 0.0235);
        let by = soft_step((tbar.y - 0.211) / 0.12) - soft_step((tbar.y - 0.789) / 0.12);
        bar = bx * by * bar_a;
    }

    // Second card over its shadow, then that layer over the first card (premultiplied).
    let shadow_layer = vec4f(0.0, 0.0, 0.0, bar);
    let top = card_b + shadow_layer * (1.0 - card_b.a);
    let outc = top.rgb + col.rgb * (1.0 - top.a);
    gpufx_write(id, vec4f(outc, 1.0));
}
