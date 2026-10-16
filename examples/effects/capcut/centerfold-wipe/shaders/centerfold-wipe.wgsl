// The first clip rolls up from the top edge like a sheet of paper, lit on the curl, uncovering the second clip.

// The crease enters at the top edge at ROLL_START and moves down at SPEED frame heights per unit of progress.
const ROLL_START: f32 = 0.087;
const SPEED: f32 = 1.5;
// Largest radius of the curl, as a fraction of the frame height; it tightens as the roll nears the bottom.
const RADIUS: f32 = 0.45;
// The crease is tilted: it sits this much lower at the left edge than at the right.
const TILT: f32 = 0.12;

fn smooth_ease(x: f32) -> f32 {
    let c = clamp(x, 0.0, 1.0);
    return c * c * (3.0 - 2.0 * c);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let p = params.progress;
    // Crease height at this column (y down); above it the sheet is wound onto the curl.
    let crease = (p - ROLL_START) * SPEED + TILT * (0.5 - uv.x);
    let radius = max(min(crease, RADIUS * (1.0 - 0.65 * smooth_ease((p - 0.45) / 0.35))), 0.0);
    // The sheet only catches the light once it is well bent, and loses it as it leaves.
    let light = smooth_ease((p - 0.28) / 0.15) * (1.0 - smooth_ease((p - 0.7) / 0.15));
    if (uv.y >= crease) {
        // Flat part of the sheet, darkened a little by the curl's shadow just under the crease.
        let shade = 1.0 - 0.25 * light * exp(-(uv.y - crease) / 0.05);
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb * shade, 1.0));
        return;
    }
    let lift = crease - uv.y;
    if (radius > 1e-4 && lift < radius) {
        // Front of the curl: unwind the arc to find where on the sheet this point came from.
        let theta = asin(lift / radius);
        let src = vec2f(uv.x, crease - radius * theta);
        let c = textureSampleLevel(first, smp, clamp(src, vec2f(0.0), vec2f(1.0)), 0.0).rgb;
        // The bend right at the crease faces the light and washes out the most.
        let near = 1.0 - sin(theta);
        let glow = light * (0.15 + 0.85 * near * near);
        gpufx_write(id, vec4f(mix(c, vec3f(1.0), glow * 0.5), 1.0));
        return;
    }
    gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0));
}
