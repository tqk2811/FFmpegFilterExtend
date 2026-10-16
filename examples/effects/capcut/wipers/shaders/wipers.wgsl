// Two corner-hinged wiper blades: one sweeps the first clip off to a greyscale second clip, the next sweeps the colour back in.

const PI: f32 = 3.14159265;
// Animation length in seconds; the first blade runs over [0, 1], the second over [0.5, 1.5].
const SPAN: f32 = 1.5;
// Share of the original colour kept in the greyscale stage.
const KEEP_COLOUR: f32 = 0.02;

// Angle of `p` around the hinge `pivot` (both with y pointing up), measured from straight down.
fn hinge_angle(p: vec2f, pivot: vec2f) -> f32 {
    let d = p - pivot;
    return atan2(-d.x, -d.y);
}

// 1 where the blade has not reached yet; `sweep` is the blade's turn, 0..1 around the full circle.
fn uncovered(p: vec2f, pivot: vec2f, sweep: f32) -> bool {
    return hinge_angle(p, pivot) >= sweep * 2.0 * PI - PI;
}

fn greyscale(c: vec3f) -> vec3f {
    let w = vec3f(0.20854, 0.70209, 0.08937) * (1.0 - KEEP_COLOUR);
    return clamp(vec3f(dot(c, w + vec3f(KEEP_COLOUR, 0.0, 0.0)),
                       dot(c, w + vec3f(0.0, KEEP_COLOUR, 0.0)),
                       dot(c, w + vec3f(0.0, 0.0, KEEP_COLOUR))), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(a, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(b, 1.0)); return; }
    let t = params.progress * SPAN;
    let p = vec2f(uv.x, 1.0 - uv.y);
    var col = b;
    // Second blade, from the top-right corner: covers everything until t = 0.5, then a quarter turn to 0.75.
    if (uncovered(p, vec2f(1.0, 1.0), mix(0.5, 0.75, clamp(t - 0.5, 0.0, 1.0)))) {
        col = greyscale(b);
    }
    // First blade, from the top-left corner: a quarter turn from 0.25 to 0.5.
    if (t < 1.0 && uncovered(p, vec2f(0.0, 1.0), mix(0.25, 0.5, t))) {
        col = a;
    }
    gpufx_write(id, vec4f(col, 1.0));
}
