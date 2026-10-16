// Hard vertical edge sweeping left to right, revealing the second clip behind it.

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let edge = clamp(params.progress, 0.0, 1.0);
    var color = textureSampleLevel(first, smp, uv, 0.0).rgb;
    // Columns left of (or on) the edge already show the incoming clip.
    if (uv.x <= edge) {
        color = textureSampleLevel(second, smp, uv, 0.0).rgb;
    }
    gpufx_write(id, vec4f(color, 1.0));
}