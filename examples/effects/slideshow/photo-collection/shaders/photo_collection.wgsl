// The second clip, fitted inside `size` of the frame with an optional border, flies in
// from one side spinning and lands tilted by `angle` over the first clip.
const PI: f32 = 3.14159265;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let base = textureSampleLevel(first, smp, uv, 0.0);
    let p = clamp(params.progress, 0.0, 1.0);
    if (p <= 0.0) { gpufx_write(id, base); return; }
    // Work in frame-height units so rotation keeps shapes.
    let aspect = globals.size.x / globals.size.y;
    let frame = vec2f(aspect, 1.0);
    let src = vec2f(textureDimensions(second));
    // The card, border included, fits inside `size` of the frame.
    let room = max(frame * params.size - 2.0 * params.border, vec2f(1e-3));
    let fit = min(room.x / src.x, room.y / src.y);
    let half_photo = 0.5 * src * fit;
    let half_card = half_photo + params.border;
    // Path: from just outside the frame to its centre, slowing down at the end.
    var start = vec2f(-(0.5 * aspect + length(half_card)), 0.0);
    if (params.direction == 1) { start = vec2f(0.5 * aspect + length(half_card), 0.0); }
    if (params.direction == 2) { start = vec2f(0.0, -(0.5 + length(half_card))); }
    if (params.direction == 3) { start = vec2f(0.0, 0.5 + length(half_card)); }
    let ease = 1.0 - (1.0 - p) * (1.0 - p);
    let centre = mix(start, vec2f(0.0), ease);
    let ang = params.angle * PI / 180.0 + params.spins * 2.0 * PI * (ease - 1.0);
    let d = (uv - 0.5) * frame - centre;
    let cs = vec2f(cos(ang), sin(ang));
    // Into the photo's own axes.
    let q = vec2f(cs.x * d.x + cs.y * d.y, -cs.y * d.x + cs.x * d.y);
    // One pixel of antialiasing on the card edge.
    let px = 1.0 / globals.size.y;
    let edge = max(abs(q.x) - half_card.x, abs(q.y) - half_card.y);
    let cover = clamp(0.5 - edge / px, 0.0, 1.0);
    if (cover <= 0.0) { gpufx_write(id, base); return; }
    // Photo inside, border outside, blended over one pixel. Without a border the photo
    // runs to the antialiased edge (clamped sampling), so no border colour leaks in.
    let photo = textureSampleLevel(second, smp, clamp(q / (2.0 * half_photo) + 0.5, vec2f(0.0), vec2f(1.0)), 0.0);
    let inside = max(abs(q.x) - half_photo.x, abs(q.y) - half_photo.y);
    let w = select(clamp(0.5 - inside / px, 0.0, 1.0), 1.0, params.border <= 0.0);
    let card = mix(params.border_color, photo, w);
    let a = card.a * cover;
    // Card over the base, straight alpha.
    let out_a = a + base.a * (1.0 - a);
    let rgb = select(vec3f(0.0), (card.rgb * a + base.rgb * base.a * (1.0 - a)) / out_a, out_a > 0.0);
    gpufx_write(id, vec4f(rgb, out_a));
}
