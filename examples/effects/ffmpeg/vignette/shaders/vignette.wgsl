// Bindings (globals, params, src, smp, out_tex) and gpufx_* helpers come from the prelude.
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let c = textureSampleLevel(src, smp, uv, 0.0);
    let aspect = vec2f(globals.size.x / globals.size.y, 1.0);
    // 0 at the center, 1 in the corners.
    let d = length((uv - 0.5) * aspect) / length(0.5 * aspect);
    let k = smoothstep(params.radius - 0.45, params.radius + 0.25, d) * params.strength * params.color.a;
    gpufx_write(id, vec4f(mix(c.rgb, params.color.rgb, k), c.a));
}
