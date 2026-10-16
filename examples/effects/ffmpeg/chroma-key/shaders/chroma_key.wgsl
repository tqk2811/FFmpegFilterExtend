fn chroma(c: vec3f) -> vec2f {
    // BT.709 Cb/Cr: compares colors independently of brightness.
    return vec2f(dot(c, vec3f(-0.1146, -0.3854, 0.5)), dot(c, vec3f(0.5, -0.4542, -0.0458)));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    let d = distance(chroma(c.rgb), chroma(params.key.rgb));
    let alpha = smoothstep(params.similarity, params.similarity + max(params.smoothness, 1e-4), d);
    let y = dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722));
    let despill = mix(c.rgb, vec3f(y), (1.0 - alpha) * params.spill);
    gpufx_write(id, vec4f(despill, c.a * alpha));
}
