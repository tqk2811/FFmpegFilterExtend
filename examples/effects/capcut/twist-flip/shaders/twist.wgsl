// Twist Flip: the picture twists like a ribbon about the diagonal, pinches at the centre and untwists onto the second clip.
//
// `progress` 0..1 is 1 s of animation time. The sheet is a front face and a back face. Each one
// is turned about an axis tilted by AXIS degrees by an angle that grows along that axis, so a
// strip across the sheet shrinks by cos(angle). Up to halfway the front shows the first clip
// (darkened) and the back the second; after it they swap and the twist unwinds from the
// opposite side. The front face carries light and shadow bands, and the whole sheet shrinks to
// 87 % and back over black.

const AXIS: f32 = 45.0;
const LIGHT: f32 = 0.77;
const PI: f32 = 3.14159265;

fn cubic(p1: f32, p2: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * p1 * r * r * s + 3.0 * p2 * r * s * s + s * s * s;
}

// y(x) of the bezier (0,0)-(k.x,k.y)-(k.z,k.w)-(1,1).
fn ease(k: vec4f, x: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var n = 0; n < 16; n++) {
        let mid = (lo + hi) * 0.5;
        if (cubic(k.x, k.z, mid) > x) { hi = mid; } else { lo = mid; }
    }
    return cubic(k.y, k.w, (lo + hi) * 0.5);
}

fn spin(v: vec2f, a: f32) -> vec2f {
    let c = cos(a);
    let s = sin(a);
    return vec2f(c * v.x - s * v.y, s * v.x + c * v.y);
}

// Darkening curve on the first clip: 0 = untouched, -1 = darkest.
fn shade_clip(c: vec4f, k: f32) -> vec4f {
    let power = 1.0 / (1.0 - k * 2.5);
    let rgb = 1.0 - pow(max(1.0 - (c.rgb + k * 0.01), vec3f(0.0)), vec3f(power));
    return clamp(vec4f(rgb, c.a), vec4f(0.0), vec4f(1.0));
}

fn overlay(top: vec3f, under: vec3f) -> vec3f {
    let lo = 2.0 * under * top;
    let hi = 1.0 - 2.0 * (1.0 - under) * (1.0 - top);
    return select(hi, lo, under < vec3f(0.5));
}

// Composites a flat colour `top` with coverage `a` over the opaque picture `c` through `mode`.
fn layer(c: vec3f, top: vec3f, a: f32, mode: i32) -> vec3f {
    var mixed: vec3f;
    if (mode == 0) { mixed = min(top, c); } else if (mode == 1) { mixed = max(top, c); } else { mixed = overlay(top, c); }
    return mix(c, mixed, a);
}

// Light and shadow bands of the front face; `tex` is in the sheet's own 0..1 frame, y up.
fn light_bands(c: vec4f, tex: vec2f, done: f32) -> vec4f {
    let swell = sin(done * PI);
    var dark = 1.0 - pow(4.0 * tex.y * (1.0 - tex.y), 0.25);
    var bright = 1.0 - pow(4.0 * tex.x * (1.0 - tex.x), 0.25);
    if (tex.y < 0.5) { dark = 0.0; }
    if (tex.x < 0.5) { bright = 0.0; }
    let da = dark * swell * LIGHT;
    let ba = bright * swell * LIGHT;
    var rgb = layer(c.rgb, vec3f(0.0), da * 0.5, 0);
    rgb = layer(rgb, vec3f(0.0), da, 2);
    rgb = layer(rgb, vec3f(0.0), da, 2);
    rgb = layer(rgb, vec3f(1.0), ba * 0.5, 1);
    rgb = layer(rgb, vec3f(1.0), ba, 2);
    rgb = layer(rgb, vec3f(1.0), ba, 2);
    return vec4f(rgb, c.a);
}

// Finds which point of a face lands on screen point `o` (-1..1, y up). Returns the sheet
// coordinate 0..1 (y up) in xy and 1 in z when the face covers `o`.
fn unwind(o: vec2f, turn: f32, tilt: f32, squeeze: f32, front: bool) -> vec3f {
    let lift = vec2f(0.0, 1.0);
    let q = spin(o * squeeze, -tilt) - lift;
    let c = cos(q.y * turn);
    let k = select(abs(c), c, front);
    if (k <= 1e-4) { return vec3f(0.0); }
    let p = (spin(vec2f(q.x / k, q.y) + lift, tilt)) / squeeze;
    if (any(abs(p) > vec2f(1.0))) { return vec3f(0.0); }
    return vec3f(p * 0.5 + 0.5, 1.0);
}

fn sample_at(tex: vec2f, late: bool, dim: f32) -> vec4f {
    let uv = vec2f(tex.x, 1.0 - tex.y);
    if (late) { return textureSampleLevel(second, smp, uv, 0.0); }
    return shade_clip(textureSampleLevel(first, smp, uv, 0.0), dim);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends.
    if (params.progress <= 0.0) {
        gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0));
        return;
    }
    if (params.progress >= 1.0) {
        gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0));
        return;
    }
    let t = params.progress;
    let done = ease(vec4f(0.45, 0.13, 0.37, 0.93), clamp((t - 0.033333) / 0.933334, 0.0, 1.0));
    let dim = -ease(vec4f(0.943439, 0.0, 0.688447, 1.0), clamp((t - 0.033333) / 0.466667, 0.0, 1.0));
    var size: f32;
    if (t < 0.433333) {
        size = mix(1.0, 0.87, ease(vec4f(0.593232, 0.0, 0.564445, 1.0), clamp((t - 0.033333) / 0.4, 0.0, 1.0)));
    } else {
        size = mix(0.87, 1.0, ease(vec4f(0.357291, 0.0, 0.284464, 1.0), clamp((t - 0.433333) / 0.533334, 0.0, 1.0)));
    }

    var turn = done * PI;
    var tilt = AXIS;
    let flipped = done > 0.5;
    if (flipped) {
        turn = PI - turn;
        tilt += 180.0;
    }
    tilt = -radians(tilt);
    // The front face scales its twist coordinate by this factor (0.67 for a 45 degree axis).
    // The front face shrinks across the twist axis: 0.67 at the fixed 45-degree axis.
    let squeeze = mix(0.67, 1.0, 1.0 - abs(sin(radians(AXIS * 2.0))));

    let o = vec2f(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0) / size;
    var colour = vec4f(0.0, 0.0, 0.0, 1.0);
    let back = unwind(o, turn, tilt, 1.0, false);
    if (back.z > 0.0) {
        colour = sample_at(back.xy, !flipped, dim);
    }
    let face = unwind(o, turn, tilt, squeeze, true);
    if (face.z > 0.0) {
        colour = light_bands(sample_at(face.xy, flipped, dim), face.xy, done);
    }
    gpufx_write(id, vec4f(colour.rgb, 1.0));
}
