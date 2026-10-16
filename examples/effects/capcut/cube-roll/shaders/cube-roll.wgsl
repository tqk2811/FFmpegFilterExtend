// The first clip is the front of a cube that tumbles a quarter turn on all three axes in perspective, greying out as it turns away, until the second clip's face settles in front.

// Distance from the camera to the cube centre, in picture widths.
const CUBE_DEPTH: f32 = 2.3698;
// Camera field of view for a square or landscape frame, in degrees.
const FOV: f32 = 30.0;
// Flat grey wash laid over the faces while they turn (sRGB 91, 88, 92).
const WASH: vec3f = vec3f(0.35686, 0.34510, 0.36078);

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by Newton steps.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var s = x;
    for (var i = 0; i < 10; i++) {
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        let dx = 3.0 * inv * inv * c.x + 6.0 * inv * s * (c.z - c.x) + 3.0 * s * s * (1.0 - c.z);
        if (abs(dx) < 1e-5) { break; }
        s = clamp(s - (bx - x) / dx, 0.0, 1.0);
    }
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Value animated from `a` to `b` between times t0 and t1 with the given easing curve.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, curve: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, curve));
}

// Two keyed segments back to back (a -> b over t0..t1, then b -> c over t1..t2).
fn keyed2(t: f32, t0: f32, t1: f32, t2: f32, a: f32, b: f32, c: f32, k0: vec4f, k1: vec4f) -> f32 {
    if (t < t1) { return keyed(t, t0, t1, a, b, k0); }
    return keyed(t, t1, t2, b, c, k1);
}

// Brightness curve on the grey wash: -1 darkens towards near black, 0 leaves it untouched.
fn darken(c: vec3f, amount: f32) -> vec3f {
    if (amount >= 0.0) { return c; }
    let gamma = 1.0 / (1.0 - amount * 2.5);
    let lowered = c + vec3f(amount * 0.01);
    return clamp(1.0 - pow(max(1.0 - lowered, vec3f(0.0)), vec3f(gamma)), vec3f(0.0), vec3f(1.0));
}

// A clip with the grey wash over it at `cover` (0..1), the wash darkened by `dim`.
fn washed(img: vec3f, cover: f32, dim: f32) -> vec3f {
    return mix(img, darken(WASH, dim), cover);
}

fn rot_x(v: vec3f, a: f32) -> vec3f {
    let c = cos(a); let s = sin(a);
    return vec3f(v.x, v.y * c - v.z * s, v.y * s + v.z * c);
}
fn rot_y(v: vec3f, a: f32) -> vec3f {
    let c = cos(a); let s = sin(a);
    return vec3f(v.x * c + v.z * s, v.y, -v.x * s + v.z * c);
}
fn rot_z(v: vec3f, a: f32) -> vec3f {
    let c = cos(a); let s = sin(a);
    return vec3f(v.x * c - v.y * s, v.x * s + v.y * c, v.z);
}
// Undo the cube orientation (applied as X * Y * Z) to bring a world vector into cube space.
fn to_cube(v: vec3f, ang: f32) -> vec3f {
    return rot_z(rot_y(rot_x(v, -ang), -ang), -ang);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress;
    // Plain clips just before the cube appears and once it has landed.
    if (t < 0.033333) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (t >= 0.91) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }

    let ratio = globals.size.x * globals.pixel_aspect / globals.size.y;
    // Camera: vertical field of view chosen so the front face exactly fills the frame.
    var fov_y = 2.0 * atan(tan(radians(FOV * 0.5)) / ratio);
    if (ratio < 1.0) {
        var portrait = 23.18 + 6.7 * ratio;
        if (ratio > 0.74) { portrait -= 0.04; }
        fov_y = min(fov_y, radians(portrait));
    }
    let tan_y = tan(fov_y * 0.5);
    // Cube half extents in picture heights: the front face has the picture's aspect.
    let m = min(ratio, 1.0) * 0.5;
    let half = vec3f(m, m / ratio, m);

    let ndc = vec2f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let dir_w = vec3f(ndc.x * tan_y * ratio, ndc.y * tan_y, -1.0);
    let ang = radians(keyed(t, 0.0, 0.9, 0.0, 90.0, vec4f(0.33333, 0.0, 0.66667, 1.0)));
    let org = to_cube(vec3f(0.0, 0.0, CUBE_DEPTH), ang);
    let dir = to_cube(dir_w, ang);

    // Ray against the box: entry point through the slab method.
    let inv = 1.0 / dir;
    let t0 = (-half - org) * inv;
    let t1 = (half - org) * inv;
    let tmin = min(t0, t1);
    let tmax = max(t0, t1);
    let near = max(max(tmin.x, tmin.y), tmin.z);
    let far = min(min(tmax.x, tmax.y), tmax.z);
    if (near > far || far <= 0.0) { gpufx_write(id, vec4f(0.0, 0.0, 0.0, 1.0)); return; }
    let p = (org + dir * near) / half;

    // Grey wash keys of each face (cover, dim) over time.
    let top_cover = 0.01 * keyed2(t, 0.0, 0.533333, 0.733333, 0.0, 89.0, 100.0,
        vec4f(0.322048, 0.0, 0.567020, 0.824127), vec4f(0.327342, 0.443907, 0.657018, 0.823154));
    let top_dim = keyed(t, 0.5, 0.8, 0.0, -1.0, vec4f(0.29, 0.051429, 0.999, 1.0));
    let front_cover = 0.01 * keyed2(t, 0.066667, 0.466667, 0.566667, 0.0, 93.0, 100.0,
        vec4f(0.42, 0.0, 0.631419, 0.772296), vec4f(0.308097, 0.575079, 0.646796, 0.921970));
    let front_dim = keyed(t, 0.333333, 0.6, 0.0, -1.0, vec4f(0.29, 0.045714, 0.999, 1.0));
    let side_cover = 0.01 * keyed(t, 0.4, 0.866667, 100.0, 0.0, vec4f(0.001, 0.0, 0.71, 1.0));
    let side_dim = keyed(t, 0.4, 0.5, -1.0, 0.0, vec4f(0.001, 0.0, 0.71, 0.982857));

    var col = WASH;
    // Face coordinates in 0..1 with v pointing down the picture.
    if (near == tmin.z && p.z > 0.0) {
        // Front: the first clip, upright.
        let fc = vec2f((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        col = washed(textureSampleLevel(first, smp, fc, 0.0).rgb, front_cover, front_dim);
    } else if (near == tmin.y && p.y > 0.0) {
        // Top: the first clip again, its top edge at the back of the cube.
        let fc = vec2f((p.x + 1.0) * 0.5, (1.0 + p.z) * 0.5);
        col = washed(textureSampleLevel(first, smp, fc, 0.0).rgb, top_cover, top_dim);
    } else if (near == tmin.x && p.x > 0.0) {
        // Right: the second clip, turned half a turn within the face.
        let fc = vec2f((p.z + 1.0) * 0.5, (1.0 + p.y) * 0.5);
        col = washed(textureSampleLevel(second, smp, fc, 0.0).rgb, side_cover, side_dim);
    }
    gpufx_write(id, vec4f(col, 1.0));
}
