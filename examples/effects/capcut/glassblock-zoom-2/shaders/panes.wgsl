// Glassblock Zoom 2, pass 3: bend the zoomed picture with a 3x3 Bezier mesh into four stretched glass panes.
//
// The mesh has 3x3 corner points, each with up to four tangent handles (5 slots per point,
// column by column). Between 0.67 s and 1.33 s the points ease from the flat grid to a pose where
// the edge midpoints fly far outside the frame, so every quarter of the picture is pulled into a
// long curved pane meeting at the centre. A compute shader cannot draw the deformed mesh, so each
// output pixel searches for the mesh coordinate that lands on it (Newton steps from 4x4 seeds
// per cell); where cells fold over, the one drawn last (lowest row, then rightmost) wins.

// Slots per mesh point: the point, the handle towards -y, +x, +y, -x.
const FLAT: array<vec2f, 45> = array<vec2f, 45>(
    vec2f(0.000000, 0.000000),
    vec2f(0.166667, 0.000000),
    vec2f(0.166667, 0.000000),
    vec2f(0.000000, 0.166667),
    vec2f(0.000000, 0.500000),
    vec2f(0.000000, 0.500000),
    vec2f(0.000000, 0.333333),
    vec2f(0.166667, 0.500000),
    vec2f(0.000000, 0.666667),
    vec2f(0.000000, 1.000000),
    vec2f(0.000000, 1.000000),
    vec2f(0.000000, 0.833333),
    vec2f(0.166667, 1.000000),
    vec2f(0.500000, 0.000000),
    vec2f(0.500000, 0.000000),
    vec2f(0.500000, 0.000000),
    vec2f(0.666667, 0.000000),
    vec2f(0.666667, 0.000000),
    vec2f(0.500000, 0.166667),
    vec2f(0.333333, 0.000000),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 0.333333),
    vec2f(0.666667, 0.500000),
    vec2f(0.500000, 0.666667),
    vec2f(0.333333, 0.500000),
    vec2f(0.500000, 1.000000),
    vec2f(0.500000, 0.833333),
    vec2f(0.666667, 1.000000),
    vec2f(0.333333, 1.000000),
    vec2f(0.333333, 1.000000),
    vec2f(1.000000, 0.000000),
    vec2f(1.000000, 0.166667),
    vec2f(1.000000, 0.166667),
    vec2f(1.000000, 0.166667),
    vec2f(0.833333, 0.000000),
    vec2f(1.000000, 0.500000),
    vec2f(1.000000, 0.333333),
    vec2f(1.000000, 0.666667),
    vec2f(1.000000, 0.666667),
    vec2f(0.833333, 0.500000),
    vec2f(1.000000, 1.000000),
    vec2f(1.000000, 0.833333),
    vec2f(0.833333, 1.000000),
    vec2f(0.833333, 1.000000),
    vec2f(0.833333, 1.000000)
);
const POSE: array<vec2f, 45> = array<vec2f, 45>(
    vec2f(0.000000, 0.000000),
    vec2f(0.500000, 0.167187),
    vec2f(0.500000, 0.167187),
    vec2f(0.500000, 0.500000),
    vec2f(-13.888889, 0.500000),
    vec2f(-13.888889, 0.500000),
    vec2f(-13.888889, 0.500000),
    vec2f(0.166667, 0.500000),
    vec2f(-13.888889, 0.500000),
    vec2f(-0.138889, 1.078125),
    vec2f(-0.138889, 1.078125),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 0.829687),
    vec2f(0.500000, -7.812500),
    vec2f(0.500000, -7.812500),
    vec2f(0.500000, -7.812500),
    vec2f(0.500000, -7.812500),
    vec2f(0.500000, -7.812500),
    vec2f(0.500000, 0.166667),
    vec2f(0.333333, -7.812500),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 8.812500),
    vec2f(0.500000, 0.833333),
    vec2f(0.500000, 8.812500),
    vec2f(0.500000, 8.812500),
    vec2f(0.500000, 8.812500),
    vec2f(1.000000, 0.000000),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 0.166406),
    vec2f(14.888889, 0.500000),
    vec2f(14.888889, 0.500000),
    vec2f(14.888889, 0.500000),
    vec2f(14.888889, 0.500000),
    vec2f(0.833333, 0.500000),
    vec2f(1.138889, 1.078125),
    vec2f(0.500000, 0.500000),
    vec2f(0.500000, 0.833594),
    vec2f(0.500000, 0.833594),
    vec2f(0.500000, 0.833594)
);

const SEEDS: i32 = 4;
const STEPS: i32 = 10;

fn cubic(p1: f32, p2: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * p1 * r * r * s + 3.0 * p2 * r * s * s + s * s * s;
}

fn ease(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 16; n++) {
        let mid = (lo + hi) * 0.5;
        if (cubic(k.x, k.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return cubic(k.y, k.w, (lo + hi) * 0.5);
}

// 0 = flat grid, 1 = full pane pose.
fn bend_at(t: f32) -> f32 {
    if (t < 0.666667) { return 0.0; }
    if (t < 0.833333) { return ease(vec4f(0.001, 0.0, 0.833333, 0.944444), (t - 0.666667) / 0.166666); }
    if (t < 1.166667) { return 1.0; }
    if (t < 1.333333) { return 1.0 - ease(vec4f(0.166667, 0.055556, 0.58, 1.0), (t - 1.166667) / 0.166666); }
    return 0.0;
}

fn curve(a: vec2f, b: vec2f, c: vec2f, d: vec2f, s: f32) -> vec2f {
    let bc = mix(b, c, s);
    return mix(mix(mix(a, b, s), bc, s), mix(bc, mix(c, d, s), s), s);
}

var<private> knots: array<vec2f, 45>;

fn knot(point: i32, slot: i32) -> vec2f {
    return knots[point * 5 + slot];
}

// Position of local coordinate q (0..1) of cell (cx, cy): a Coons-style blend of the four edge curves.
fn cell_point(cx: i32, cy: i32, q: vec2f) -> vec2f {
    let a = cx * 3 + cy;
    let b = a + 3;
    let c = a + 1;
    let d = b + 1;
    // Edges along x (near and far row) and along y (near and far column).
    let n0 = knot(a, 0); let n1 = knot(a, 2); let n2 = knot(b, 4); let n3 = knot(b, 0);
    let f0 = knot(c, 0); let f1 = knot(c, 2); let f2 = knot(d, 4); let f3 = knot(d, 0);
    let l0 = knot(a, 0); let l1 = knot(a, 3); let l2 = knot(c, 1); let l3 = knot(c, 0);
    let r0 = knot(b, 0); let r1 = knot(b, 3); let r2 = knot(d, 1); let r3 = knot(d, 0);

    let left = curve(l0, l1, l2, l3, q.y);
    let right = curve(r0, r1, r2, r3, q.y);
    let ey = smoothstep(0.0, 1.0, q.y);
    let push_x = vec2f(mix(-mix(n0.x, f0.x, ey), 1.0 - mix(n3.x, f3.x, ey), q.x) + mix(left.x, right.x - 1.0, q.x), 0.0);
    let across = curve(left, mix(n1, f1, vec2f(ey, q.y)) + push_x, mix(n2, f2, vec2f(ey, q.y)) + push_x, right, q.x);

    let near = curve(n0, n1, n2, n3, q.x);
    let far = curve(f0, f1, f2, f3, q.x);
    let ex = smoothstep(0.0, 1.0, q.x);
    let push_y = vec2f(0.0, mix(-mix(l0.y, r0.y, ex), 1.0 - mix(l3.y, r3.y, ex), q.y) + mix(near.y, far.y - 1.0, q.y));
    let down = curve(near, mix(l1, r1, vec2f(q.x, ex)) + push_y, mix(l2, r2, vec2f(q.x, ex)) + push_y, far, q.y);
    return vec2f(across.x, down.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, whatever the passes before did.
    if (params.progress <= 0.0) {
        gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0));
        return;
    }
    if (params.progress >= 1.0) {
        gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0));
        return;
    }
    let m = bend_at(params.progress * 2.0);
    if (m <= 0.0) {
        gpufx_write(id, textureSampleLevel(zoomed, smp, uv, 0.0));
        return;
    }
    for (var i = 0; i < 45; i++) {
        knots[i] = mix(FLAT[i], POSE[i], m);
    }
    // The mesh works with y pointing up the picture.
    let target_pt = vec2f(uv.x, 1.0 - uv.y);
    let tol = 0.75 / globals.size.y;
    var best = -1.0;
    var best_uv = vec2f(0.0);
    for (var cell = 0; cell < 4; cell++) {
        let cx = cell / 2;
        let cy = cell % 2;
        for (var sd = 0; sd < SEEDS * SEEDS; sd++) {
            var q = (vec2f(f32(sd % SEEDS), f32(sd / SEEDS)) + 0.5) / f32(SEEDS);
            var hit = false;
            for (var n = 0; n < STEPS; n++) {
                let p = cell_point(cx, cy, q);
                let err = p - target_pt;
                if (length(err) < tol) { hit = true; break; }
                let h = 1e-3;
                let du = (cell_point(cx, cy, q + vec2f(h, 0.0)) - p) / h;
                let dv = (cell_point(cx, cy, q + vec2f(0.0, h)) - p) / h;
                let det = du.x * dv.y - du.y * dv.x;
                if (abs(det) < 1e-9) { break; }
                let step = vec2f(dv.y * err.x - dv.x * err.y, -du.y * err.x + du.x * err.y) / det;
                q = clamp(q - step, vec2f(-0.05), vec2f(1.05));
            }
            if (!hit || any(q < vec2f(-1e-3)) || any(q > vec2f(1.001))) { continue; }
            let grid = (vec2f(f32(cx), f32(cy)) + clamp(q, vec2f(0.0), vec2f(1.0))) * 0.5;
            // Later rows of the 32x32 mesh, then later columns, are drawn on top.
            let order = floor(grid.y * 31.0) * 64.0 + grid.x * 31.0;
            if (order > best) {
                best = order;
                best_uv = grid;
            }
        }
    }
    if (best < 0.0) {
        gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0));
        return;
    }
    gpufx_write(id, textureSampleLevel(zoomed, smp, vec2f(best_uv.x, 1.0 - best_uv.y), 0.0));
}
