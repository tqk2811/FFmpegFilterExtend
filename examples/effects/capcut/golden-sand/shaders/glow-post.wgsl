// Golden Sand glow, last step: screen the glow over the band layer.

fn idle() -> bool { return params.progress <= 0.0 || params.progress >= 1.0; }

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id) || idle()) { return; }
    let uv = gpufx_uv(id);
    let src = textureSampleLevel(band, smp, uv, 0.0);
    let halo = textureSampleLevel(g_b, smp, uv, 0.0).rgb;
    let peak = max(max(halo.r, halo.g), halo.b);
    let rgb = 1.0 - (1.0 - src.rgb) * (1.0 - halo);
    gpufx_write(id, vec4f(rgb, src.a + peak - src.a * peak));
}
