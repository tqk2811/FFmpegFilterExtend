// Horizontal half of the wide blur that feeds the glow.

// Glow radius as a gaussian sigma, in pixels of a 1080-pixel-high frame.
const GLOW_SIGMA: f32 = 24.0;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let size = vec2i(textureDimensions(streaks));
    let p = vec2i(id.xy);
    let sigma = GLOW_SIGMA * globals.size.y / 1080.0;
    let r = i32(min(ceil(sigma * 2.5), 96.0));
    var sum = vec3f(0.0);
    var wsum = 0.0;
    for (var i = -r; i <= r; i++) {
        let w = exp(-f32(i * i) / (2.0 * sigma * sigma));
        sum += w * textureLoad(streaks, clamp(p + vec2i(i, 0), vec2i(0), size - 1), 0).rgb;
        wsum += w;
    }
    gpufx_write(id, vec4f(sum / wsum, 1.0));
}
