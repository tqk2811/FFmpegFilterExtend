fn gray(c: vec4f) -> vec4f {
    let y = dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722));
    return vec4f(vec3f(y), c.a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = params.progress;
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    // 0..1/3: first to gray, 1/3..2/3: gray crossfade, 2/3..1: gray to second.
    let a2 = mix(a, gray(a), clamp(p * 3.0, 0.0, 1.0));
    let b2 = mix(gray(b), b, clamp(p * 3.0 - 2.0, 0.0, 1.0));
    gpufx_write(id, mix(a2, b2, clamp(p * 3.0 - 1.0, 0.0, 1.0)));
}
