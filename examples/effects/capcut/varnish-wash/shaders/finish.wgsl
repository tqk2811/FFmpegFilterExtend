// Varnish Wash, pass 2: shade the liquid mask as glossy metal, refract the second clip through it
// and lay it over the first clip.

const SPAN: f32 = 1.966667;
const REFRACT: f32 = 1.0;
const LIGHT_HEIGHT: f32 = 0.8;
const LIGHT_GAIN: f32 = 1.0;
const ROUGHNESS: f32 = 0.04;
const METALLIC: f32 = 0.8;
const GLOSS_DEPTH: f32 = 0.07;
const AMBIENT: f32 = 1.0;

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

fn keyed(t: f32, t0: f32, t1: f32, a: f32, b: f32) -> f32 {
    let x = clamp((t - t0) / (t1 - t0), 0.0, 1.0);
    return mix(a, b, bezier_ease(x, 0.33333333, 0.0, 0.66666667, 1.0));
}

// Height stored by pass 1, read at a bottom-up coordinate.
fn height_at(p: vec2f) -> f32 {
    let c = textureSampleLevel(blobs, smp, vec2f(p.x, 1.0 - p.y), 0.0).rgb;
    return c.x + c.y / 255.0 + c.z / 65025.0;
}

// Mirror-repeat a coordinate into [0, 1].
fn bounce(p: vec2f) -> vec2f {
    return abs((p + 1.0) - 2.0 * floor((p + 1.0) * 0.5) - 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let progress = clamp(params.progress, 0.0, 1.0);
    // Exact clips at the ends of the transition.
    if (progress <= 0.0) { gpufx_write(id, textureSampleLevel(first, smp, uv, 0.0)); return; }
    if (progress >= 1.0) { gpufx_write(id, textureSampleLevel(second, smp, uv, 0.0)); return; }

    let base = textureSampleLevel(first, smp, uv, 0.0);
    let p = vec2f(uv.x, 1.0 - uv.y);
    let cover = textureSampleLevel(blobs, smp, uv, 0.0).a;
    if (cover <= 0.0) { gpufx_write(id, base); return; }

    let dy = vec2f(0.0, 2.0 / globals.size.y);
    let dx = vec2f(2.0 / globals.size.x, 0.0);
    let normal = vec3f(
        (height_at(p - dx) - height_at(p + dx)) * 0.5,
        (height_at(p - dy) - height_at(p + dy)) * 0.5,
        height_at(p) * GLOSS_DEPTH);
    let q = bounce(p + normal.xy * REFRACT);
    let tint = textureSampleLevel(second, smp, vec2f(q.x, 1.0 - q.y), 0.0).rgb * cover;

    let angle = radians(90.0 - keyed(progress * SPAN, 0.333333, 1.766667, 0.0, 96.0));
    let toward = vec3f(cos(angle), sin(angle), LIGHT_HEIGHT);
    let halfway = normalize(vec3f(0.0, 0.0, 1.0) + toward);
    var glint = 0.0;
    if (length(normal) > 0.0) {
        glint = pow(max(dot(normalize(normal), halfway), 0.0), 1.0 / ROUGHNESS);
    }
    // Premultiplied over: the highlight fades out with the coverage at the pool edge.
    let layer = tint * AMBIENT + LIGHT_GAIN * mix(vec3f(1.0), tint, METALLIC) * glint * cover;
    gpufx_write(id, vec4f(base.rgb * (1.0 - cover) + layer, 1.0));
}
