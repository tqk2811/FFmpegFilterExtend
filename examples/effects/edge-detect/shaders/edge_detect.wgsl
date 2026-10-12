fn luma(p: vec2i, size: vec2i) -> f32 {
    return dot(textureLoad(src, clamp(p, vec2i(0), size - 1), 0).rgb, vec3f(0.2126, 0.7152, 0.0722));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(src));
    let p = vec2i(id.xy);
    let tl = luma(p + vec2i(-1, -1), size);
    let t = luma(p + vec2i(0, -1), size);
    let tr = luma(p + vec2i(1, -1), size);
    let l = luma(p + vec2i(-1, 0), size);
    let r = luma(p + vec2i(1, 0), size);
    let bl = luma(p + vec2i(-1, 1), size);
    let b = luma(p + vec2i(0, 1), size);
    let br = luma(p + vec2i(1, 1), size);
    let gx = (tr + 2.0 * r + br) - (tl + 2.0 * l + bl);
    let gy = (bl + 2.0 * b + br) - (tl + 2.0 * t + tr);
    let e = clamp(length(vec2f(gx, gy)) * params.strength, 0.0, 1.0);
    let c = textureLoad(src, p, 0);
    let edges = params.color.rgb * e;
    gpufx_write(id, vec4f(mix(c.rgb, edges, params.blend), c.a));
}
