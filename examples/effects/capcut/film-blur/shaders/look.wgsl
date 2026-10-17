// Film blur, step 1: the current clip on a half-resolution grid, smeared sideways like a weak analogue signal and given a punchy colour grade.

const CLOCK_START: f32 = 0.3333333;
const CLOCK_SPAN: f32 = 1.3333333;
const CUT_AT: f32 = 1.0;
// How much of the analogue smear is mixed in, and how strongly the colour grade applies.
const SMEAR_MIX: f32 = 0.3;
const GRADE_MIX: f32 = 0.8;

fn clip_at(uv: vec2f, use_second: bool) -> vec3f {
    if (use_second) { return textureSampleLevel(second, smp, uv, 0.0).rgb; }
    return textureSampleLevel(first, smp, uv, 0.0).rgb;
}

fn to_ycc(c: vec3f) -> vec3f {
    let y = dot(c, vec3f(0.299, 0.587, 0.114));
    return vec3f(y, (c.b - y) * 0.565, (c.r - y) * 0.713);
}

fn from_ycc(c: vec3f) -> vec3f {
    return vec3f(c.x + 1.403 * c.z, c.x - 0.344 * c.y - 0.714 * c.z, c.x + 1.77 * c.y);
}

// Contrast-and-saturation grade: a cubic curve per channel with a small pull away from the luma.
fn grade(c: vec3f) -> vec3f {
    let l = dot(c, vec3f(0.299, 0.587, 0.114));
    let r = 0.0409 + c.r * (0.3888 + c.r * (1.5483 - 1.0045 * c.r)) - 0.1019 * (l - c.r);
    let g = 0.0175 + c.g * (0.6165 + c.g * (1.0801 - 0.7293 * c.g)) - 0.1037 * (l - c.g);
    let b = 0.0301 + c.b * (0.2779 + c.b * (1.7487 - 1.0753 * c.b)) - 0.0796 * (l - c.b);
    return clamp(vec3f(r, g, b), vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let dims = vec2f(textureDimensions(first));
    let t = CLOCK_START + clamp(params.progress, 0.0, 1.0) * CLOCK_SPAN;
    let late = t >= CUT_AT;
    // Centre of this pixel's half-resolution cell: a bilinear tap there averages the 2x2 block.
    let cell = vec2f(id.xy / vec2u(2u));
    let uv = (cell * 2.0 + 1.0) / dims;
    let step = 1.0 / (dims / min(dims.x, dims.y) * 720.0);

    let here = clip_at(uv, late);
    var trail = here;
    for (var k = 1; k <= 8; k++) {
        trail += clip_at(uv - vec2f(f32(k) * step.x, 0.0), late);
    }
    let peaked = clamp(here + (here - trail / 9.0) * 0.6, vec3f(0.0), vec3f(1.0));
    var ycc = to_ycc(peaked);
    let ghost = to_ycc(clip_at(uv - vec2f(8.0 * step.x, 0.0), late));
    ycc = vec3f(ycc.x, mix(ycc.yz, ghost.yz, vec2f(0.6)));
    let smeared = mix(here, clamp(from_ycc(ycc), vec3f(0.0), vec3f(1.0)), SMEAR_MIX);
    gpufx_write(id, vec4f(mix(smeared, grade(smeared), GRADE_MIX), 1.0));
}
