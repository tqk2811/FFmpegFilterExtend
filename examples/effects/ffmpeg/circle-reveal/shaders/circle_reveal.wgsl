@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let aspect = vec2f(globals.size.x / globals.size.y, 1.0);
    let d = length((uv - params.center) * aspect);
    // Radius that covers the farthest corner from the center.
    let far = max(max(length(params.center * aspect), length((vec2f(1.0, 0.0) - params.center) * aspect)),
                  max(length((vec2f(0.0, 1.0) - params.center) * aspect), length((1.0 - params.center) * aspect)));
    // smoothstep needs distinct edges: softness 0 would be undefined.
    let s = max(params.softness, 1e-4);
    let r = params.progress * (far + s);
    let m = 1.0 - smoothstep(r - s, r, d);
    let a = textureSampleLevel(first, smp, uv, 0.0);
    let b = textureSampleLevel(second, smp, uv, 0.0);
    gpufx_write(id, mix(a, b, m));
}
