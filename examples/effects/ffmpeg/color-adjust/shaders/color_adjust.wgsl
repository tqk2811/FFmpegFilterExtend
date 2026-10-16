fn hue_rotate(c: vec3f, deg: f32) -> vec3f {
    // Rotation around the gray axis.
    let a = radians(deg);
    let k = vec3f(0.57735);
    return c * cos(a) + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - cos(a));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let s = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    var c = s.rgb;
    c += vec3f(params.temperature, 0.0, -params.temperature) * 0.1;
    c += vec3f(params.tint * 0.05, -params.tint * 0.1, params.tint * 0.05);
    c = hue_rotate(c, params.hue);
    let luma = dot(c, vec3f(0.2126, 0.7152, 0.0722));
    c = mix(vec3f(luma), c, params.saturation);
    c = (c - 0.5) * params.contrast + 0.5 + params.brightness;
    c = pow(max(c, vec3f(0.0)), vec3f(1.0 / params.gamma));
    gpufx_write(id, vec4f(c, s.a));
}
