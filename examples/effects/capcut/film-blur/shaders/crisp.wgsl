// Film blur, step 2: a light horizontal luma sharpen on the half-resolution grid.

fn to_ycc(c: vec3f) -> vec3f {
    let y = dot(c, vec3f(0.299, 0.587, 0.114));
    return vec3f(y, (c.b - y) * 0.565, (c.r - y) * 0.713);
}

fn from_ycc(c: vec3f) -> vec3f {
    return vec3f(c.x + 1.403 * c.z, c.x - 0.344 * c.y - 0.714 * c.z, c.x + 1.77 * c.y);
}

const TAPS: i32 = 5;
const AMOUNT: f32 = 0.01;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let dims = vec2f(textureDimensions(look));
    let cell = vec2f(id.xy / vec2u(2u));
    let uv = (cell * 2.0 + 1.0) / dims;
    let step = 1.0 / (dims / min(dims.x, dims.y) * 720.0);
    let here = textureSampleLevel(look, smp, uv, 0.0).rgb;
    var sum = here;
    for (var k = 1; k <= TAPS; k++) {
        sum += textureSampleLevel(look, smp, uv - vec2f(f32(k) * step.x, 0.0), 0.0).rgb;
    }
    let soft = to_ycc(sum / f32(TAPS + 1));
    let own = to_ycc(here);
    let out = vec3f(own.x + (own.x - soft.x) * AMOUNT * 40.0, mix(own.yz, soft.yz, vec2f(min(1.0, AMOUNT * 5.0))));
    gpufx_write(id, vec4f(clamp(from_ycc(out), vec3f(0.0), vec3f(1.0)), 1.0));
}
