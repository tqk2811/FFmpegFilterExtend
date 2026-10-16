// Snapshot glam, step 1: the first clip tips back and away in perspective, the second swings up from below and comes forward, slightly skewed.

// The whole transition spans this many seconds of animation time.
const SPAN: f32 = 1.0;
// The clips swap at this time.
const SWAP_AT: f32 = 0.366667;
// Horizontal field of view of the virtual camera, in degrees.
const FOV_X: f32 = 39.5977527;
// Composition width in pixels; depth offsets below are in the same pixels.
const COMP_W: f32 = 504.0;
const PUSH_DEPTH: f32 = 800.0;

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(u: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(c.x, c.z, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(c.y, c.w, 0.5 * (lo + hi));
}

// Value moving from `a` to `b` between times t0 and t1 (held outside that span).
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, c: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, ease(x, c));
}

fn mirror01(q: vec2f) -> vec2f {
    return abs(((q + 1.0) % 2.0 + 2.0) % 2.0 - 1.0);
}

// Distance the card is pushed away from the camera, in composition pixels.
fn depth_now(t: f32) -> f32 {
    if (t < 0.4) { return keyed(t, 0.0, 0.4, 0.0, PUSH_DEPTH, vec4f(0.333333, 0.0, 0.151698, 1.0)); }
    return keyed(t, 0.4, 0.733333, PUSH_DEPTH, 0.0, vec4f(1.0, 0.0, 0.666667, 1.0));
}

// Where the camera ray through `uv` hits a full-frame card tilted by `tilt` degrees about its
// horizontal axis and pushed `depth` pixels back; returns the card uv, or -1 when it misses.
fn card_hit(uv: vec2f, tilt: f32, depth: f32) -> vec2f {
    let aspect = globals.size.x / globals.size.y;
    // World units: half the frame width; y up, camera on +z looking at the frame plane z = 0.
    let dist = 1.0 / tan(radians(FOV_X * 0.5));
    let eye = vec3f(0.0, 0.0, dist);
    let aim = vec3f((uv.x - 0.5) * 2.0, (0.5 - uv.y) * 2.0 / aspect, 0.0);
    let centre = vec3f(0.0, 0.0, -depth * 2.0 / COMP_W);
    let a = radians(tilt);
    let ca = cos(a);
    let sa = sin(a);
    // Inverse of the card rotation (about +x), applied to the ray.
    let o = eye - centre;
    let dir = aim - eye;
    let lo = vec3f(o.x, ca * o.y + sa * o.z, -sa * o.y + ca * o.z);
    let ld = vec3f(dir.x, ca * dir.y + sa * dir.z, -sa * dir.y + ca * dir.z);
    if (abs(ld.z) < 1e-6) { return vec2f(-1.0); }
    let s = -lo.z / ld.z;
    if (s <= 0.0) { return vec2f(-1.0); }
    let hit = lo.xy + ld.xy * s;
    let q = vec2f(hit.x * 0.5 + 0.5, 0.5 - hit.y * aspect * 0.5);
    if (any(q < vec2f(0.0)) || any(q > vec2f(1.0))) { return vec2f(-1.0); }
    return q;
}

// Shear-like twist of the second clip: each point turns by `turn` about its foot on a line
// through the centre at `axis` (both radians), in bottom-up texture space; edges mirror.
fn skew(q: vec2f, turn: f32, axis: f32) -> vec2f {
    let p = vec2f(q.x, 1.0 - q.y) - 0.5;
    let k_perp = tan(axis + 1.5707963);
    let k_axis = tan(axis);
    var foot: vec2f;
    foot.x = (p.y - k_axis * p.x) / (k_perp - k_axis);
    foot.y = foot.x * k_perp;
    let d = p - foot;
    let c = cos(turn);
    let s = sin(turn);
    let r = vec2f(c * d.x - s * d.y, s * d.x + c * d.y) + foot + 0.5;
    let m = mirror01(r);
    return vec2f(m.x, 1.0 - m.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;
    let depth = depth_now(t);
    var c = vec3f(0.0);
    if (t < SWAP_AT) {
        let tilt = keyed(t, 0.0, 0.366667, 0.0, 85.0, vec4f(0.711959, 0.0, 0.9999, 1.0));
        let q = card_hit(uv, tilt, depth);
        if (q.x >= 0.0) { c = textureSampleLevel(first, smp, q, 0.0).rgb; }
    } else {
        let tilt = keyed(t, 0.366667, 0.733333, -90.0, 0.0, vec4f(0.0001, 0.0, 0.274250, 1.0));
        let q = card_hit(uv, tilt, depth);
        if (q.x >= 0.0) {
            let turn = radians(keyed(t, 0.6, 0.766667, 5.0, 0.0, vec4f(0.333333, 0.0, 0.666667, 1.0)));
            var axis = keyed(t, 0.366667, 0.766667, 270.0, 360.0, vec4f(0.825758, 0.0, 0.666667, 1.0));
            if (abs(axis % 90.0) < 0.01) { axis -= 0.01; }
            c = textureSampleLevel(second, smp, skew(q, turn, radians(axis)), 0.0).rgb;
        }
    }
    gpufx_write(id, vec4f(c, 1.0));
}
