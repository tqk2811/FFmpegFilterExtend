// The clips sit on the front and right faces of a cube that swings a quarter turn to the left, the first dimming and the second flaring as they trade places.

// Vertical field of view of the camera, in degrees.
const FOV: f32 = 60.5;
// Edge of the cube in scene units, and its resting distance from the camera.
const EDGE: f32 = 3.0;
const REST_Z: f32 = -4.07;
// Smooth in/out curve shared by several keys.
const EASE_IO: vec4f = vec4f(0.33333333, 0.0, 0.66666667, 1.0);
// Straight-line key.
const LINEAR: vec4f = vec4f(0.16666667, 0.16666667, 0.83333333, 0.83333333);
// Slow start, very fast middle, long settle: the swing of the cube.
const SWING: vec4f = vec4f(0.66830899, 0.008496309, 0.078329249, 0.99530264);

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
        let m = 0.5 * (lo + hi);
        let inv = 1.0 - m;
        let bx = 3.0 * inv * inv * m * c.x + 3.0 * inv * m * m * c.z + m * m * m;
        if (bx > x) { hi = m; } else { lo = m; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

// Value animated from `a` to `b` between times t0 and t1, held outside.
fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32, curve: vec4f) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, curve));
}

// Exposure in stops, applied in linear light (gamma 2.2).
fn expose(c: vec3f, stops: f32) -> vec3f {
    let lin = pow(max(c, vec3f(0.0)), vec3f(2.2)) * exp2(stops);
    return clamp(pow(lin, vec3f(1.0 / 2.2)), vec3f(0.0), vec3f(1.0));
}

// Contrast scaled around a pivot grey (amount 1 leaves the colour untouched).
fn squeeze(c: vec3f, amount: f32, pivot: f32) -> vec3f {
    return clamp((c - vec3f(pivot)) * amount + vec3f(pivot), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress;

    // Dark backdrop: grey at the top fading to black at the bottom.
    var col = vec3f((38.0 - 36.0 * uv.y) / 255.0);

    // Camera and cube proportions follow the frame shape.
    let ratio = globals.size.x * globals.pixel_aspect / globals.size.y;
    let tall = 1.0 / ratio;
    let half_fov = radians(FOV * 0.5);
    let tan_y = min(tan(half_fov), tan(half_fov) * tall);
    var half = vec3f(EDGE, EDGE * tall, EDGE) * 0.5;
    var shift = 0.0;
    if (tall > 1.0) {
        half = vec3f(EDGE / tall, EDGE, EDGE / tall) * 0.5;
        // Bring the camera closer by the half-depth the slimmer cube lost, so the front face still fills the frame.
        shift = (EDGE - EDGE / tall) * 0.5;
    }

    // Keys over the transition.
    let depth = select(keyed(t, 0.333333, 0.633333, -4.37, REST_Z, EASE_IO),
                       keyed(t, 0.133333, 0.333333, REST_Z, -4.37, EASE_IO), t < 0.333333) + shift;
    let turn = radians(keyed(t, 0.133333, 0.633333, 0.0, -90.0, SWING));
    let out_stops = keyed(t, 0.3, 0.333333, 0.0, -2.8, LINEAR);
    let out_contrast = select(keyed(t, 0.333333, 0.466667, 0.51, 1.0, LINEAR),
                              keyed(t, 0.133333, 0.333333, 1.0, 0.51, LINEAR), t < 0.333333);
    let in_stops = select(keyed(t, 0.333333, 0.5, 1.1, 0.0, EASE_IO),
                          keyed(t, 0.3, 0.333333, -3.0, 1.1, EASE_IO), t < 0.333333);
    let in_contrast = keyed(t, 0.333333, 0.5, 0.47, 1.0, LINEAR);

    // Ray from the camera at the origin, moved into the cube's own frame (turned about Y).
    let ndc = vec2f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let ray_w = vec3f(ndc.x * tan_y * ratio, ndc.y * tan_y, -1.0);
    let org_w = vec3f(0.0, 0.0, -depth);
    let cs = cos(turn);
    let sn = sin(turn);
    let ray = vec3f(ray_w.x * cs - ray_w.z * sn, ray_w.y, ray_w.x * sn + ray_w.z * cs);
    let org = vec3f(org_w.x * cs - org_w.z * sn, org_w.y, org_w.x * sn + org_w.z * cs);

    // Entry face of the box (slab method); only the two faces carrying a clip are drawn.
    let inv = 1.0 / ray;
    let ta = (-half - org) * inv;
    let tb = (half - org) * inv;
    let tmin = min(ta, tb);
    let tmax = max(ta, tb);
    let near = max(max(tmin.x, tmin.y), tmin.z);
    let far = min(min(tmax.x, tmax.y), tmax.z);
    if (near <= far && far > 0.0) {
        let p = (org + ray * near) / half;
        if (near == tmin.z && p.z > 0.0) {
            // Front face: the outgoing clip.
            let fc = vec2f((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
            var c = textureSampleLevel(first, smp, fc, 0.0).rgb;
            c = squeeze(expose(c, out_stops), out_contrast, 0.25);
            col = c;
        } else if (near == tmin.x && p.x > 0.0) {
            // Right face: the incoming clip.
            let fc = vec2f((1.0 - p.z) * 0.5, (1.0 - p.y) * 0.5);
            var c = textureSampleLevel(second, smp, fc, 0.0).rgb;
            c = expose(squeeze(c, in_contrast, 0.43), in_stops);
            col = c;
        }
    }
    gpufx_write(id, vec4f(col, 1.0));
}
