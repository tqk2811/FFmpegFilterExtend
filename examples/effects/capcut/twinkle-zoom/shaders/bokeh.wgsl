// Twinkle Zoom, pass 4: hexagonal bokeh, where bright spots flare into the shape of the aperture.

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, x1: f32, y1: f32, x2: f32, y2: f32) -> f32 {
    var s = x;
    for (var i = 0; i < 8; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * x1 + 3.0 * inv * s * s * x2 + s * s * s;
        let dx = 3.0 * inv * inv * x1 + 6.0 * inv * s * (x2 - x1) + 3.0 * s * s * (1.0 - x2);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * y1 + 3.0 * inv * s * s * y2 + s * s * s;
}

// Bokeh strength 0..1: rises to its peak at the midpoint, gone again by 5/6 of the way.
fn bokeh_amount(p: f32) -> f32 {
    var taps = 0.0;
    if (p < 0.5) {
        taps = 35.0 * bezier_ease(p / 0.5, 0.33333, 0.0, 0.66667, 1.0);
    } else if (p < 0.833333) {
        taps = 35.0 * (1.0 - bezier_ease((p - 0.5) / 0.333333, 0.33333, 0.0, 0.66667, 1.0));
    }
    return taps / 79.0;
}

const SIDES: i32 = 6;
const RADIUS: f32 = 11.0;

// Corner k of the aperture hexagon (k = 0 at the top, then counter-clockwise).
fn corner(k: i32) -> vec2f {
    let a = 6.2831853 * f32(k % SIDES) / f32(SIDES);
    return vec2f(-RADIUS * sin(a), RADIUS * cos(a));
}

// Same hexagon as corner(), as three pairs of parallel edges: the apothem is RADIUS * cos(30 deg).
fn inside_hexagon(q: vec2f) -> bool {
    let apothem = RADIUS * 0.8660254;
    return abs(q.x) <= apothem
        && abs(dot(q, vec2f(0.5, 0.8660254))) <= apothem
        && abs(dot(q, vec2f(-0.5, 0.8660254))) <= apothem;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let amount = bokeh_amount(params.progress);
    let strength = pow(amount, 0.35);
    if (strength < 0.01) {
        gpufx_write(id, textureSampleLevel(soft, smp, uv, 0.0));
        return;
    }
    let radius = 7.5 * amount * 0.7;
    // Aperture units -> uv: the aperture is measured on a frame whose short side is 720 px.
    let to_uv = radius * min(globals.size.x, globals.size.y) / (globals.size * 720.0);
    let stride = mix(2.0, 0.5, strength) * 1.5;
    var peak = vec4f(0.0);
    var sum = vec4f(0.0);
    var total = vec4f(0.4);
    // Filled aperture: only lifts the brightest value seen.
    let cells = max(5.0, 12.0 / stride * 0.825);
    if (strength >= 0.3) {
        for (var i = 0; i < 30; i++) {
            if (f32(i) > cells) { break; }
            for (var j = 0; j < 30; j++) {
                if (f32(j) > cells) { break; }
                let q = vec2f(mix(-RADIUS, RADIUS, f32(i) / cells), mix(-RADIUS, RADIUS, f32(j) / cells));
                if (!inside_hexagon(q)) { continue; }
                let c = textureSampleLevel(soft, smp, uv - q * to_uv, 0.0);
                peak = max(peak, c * 0.7);
            }
        }
    }
    // Rim of the aperture: highlight-weighted average.
    for (var k = 0; k < SIDES; k++) {
        let a = corner(k);
        let b = corner(k + 1);
        let span = max(length(a - b) / 1.5 * 0.75, 3.0);
        for (var t = 0; t < 40; t++) {
            let s = f32(t) * stride;
            if (s > span) { break; }
            let c = textureSampleLevel(soft, smp, uv - mix(a, b, s / span) * to_uv, 0.0);
            peak = max(peak, c);
            let w = pow(c, vec4f(9.0)) * 539.45 + 0.4;
            sum += w * c;
            total += w;
        }
    }
    let avg = clamp(sum / total, vec4f(0.0), vec4f(1.0));
    gpufx_write(id, mix(avg, peak, clamp(avg * 2.0, vec4f(0.0), vec4f(1.0))));
}
