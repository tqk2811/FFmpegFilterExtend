@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let c = textureLoad(src, p, 0);
    var blur = vec3f(0.0);
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            blur += textureLoad(src, clamp(p + vec2i(x, y), vec2i(0), size - 1), 0).rgb;
        }
    }
    blur /= 9.0;
    gpufx_write(id, vec4f(c.rgb + (c.rgb - blur) * params.amount, c.a));
}
