@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(tmp));
    let p = vec2i(id.xy);
    let r = i32(ceil(params.radius));
    let sigma = max(params.radius / 2.0, 0.0001);
    var sum = vec4f(0.0);
    var wsum = 0.0;
    for (var i = -r; i <= r; i++) {
        let w = exp(-f32(i * i) / (2.0 * sigma * sigma));
        sum += w * textureLoad(tmp, clamp(p + vec2i(0, i), vec2i(0), size - 1), 0);
        wsum += w;
    }
    gpufx_write(id, sum / wsum);
}
