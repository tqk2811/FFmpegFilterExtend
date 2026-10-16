// Heat Flash, pass 4: screen the tinted glow over the clip, then fade a flickering film-burn flash over it.

const START: f32 = 0.4;
const LENGTH: f32 = 1.333333;
const SWAP: f32 = 0.933333;
const TINT: vec3f = vec3f(0.976471, 0.652197, 0.509296);
// Aspect (width / height) of the generated burn picture, filled into the frame like a cover crop.
const BURN_ASPECT: f32 = 0.592593;

fn ramp(t: f32, t0: f32, t1: f32, a: f32, b: f32) -> f32 {
    return mix(a, b, clamp((t - t0) / (t1 - t0), 0.0, 1.0));
}

fn glow_gain(t: f32) -> f32 {
    if (t < SWAP) { return ramp(t, 0.6, 0.966667, 0.0, 2.8); }
    return ramp(t, 0.966667, 1.366667, 1.0, 0.0);
}

fn flash_opacity(t: f32) -> f32 {
    if (t < 0.966667) { return ramp(t, 0.6, 0.966667, 0.0, 0.9); }
    return ramp(t, 0.966667, 1.3, 0.9, 0.0);
}

// Look of the burn picture over time: x = 0 dim film strip, 1 lit film strip,
// 2 orange wash, 3 white-hot wash; y = brightness. It flickers between strip states,
// then flares into a white-hot wash around the cut.
fn burn_look(t: f32) -> vec2f {
    if (t < 0.74) { return vec2f(0.0, 0.6); }
    if (t < 0.83) { return vec2f(1.0, 1.0); }
    if (t < 0.92) { return vec2f(0.0, 0.6); }
    if (t < 1.02) { return vec2f(2.0, 1.0); }
    return vec2f(3.0, 1.0);
}

// Rounded sprocket holes in a row centred at height y0.
fn holes(p: vec2f, y0: f32, h: f32) -> f32 {
    let cell = fract(p.x * 3.0 + 0.15) - 0.5;
    let dx = max(abs(cell) - 0.16, 0.0);
    let dy = max(abs(p.y - y0) - h, 0.0);
    return 1.0 - smoothstep(0.02, 0.09, length(vec2f(dx * 0.33, dy)));
}

fn film_strip(p: vec2f, lit: bool) -> vec3f {
    let band = smoothstep(0.36, 0.42, p.y);
    var c: vec3f;
    if (lit) {
        c = mix(vec3f(1.0, 0.93, 0.05), vec3f(0.95, 0.4, 0.05), band);
        c = mix(c, vec3f(1.0, 1.0, 0.85), 0.3 * holes(p, 0.06, 0.05));
        c = mix(c, vec3f(1.0, 0.95, 0.1), 0.3 * holes(p, 0.53, 0.06));
        c *= 1.0 - 0.6 * smoothstep(0.85, 0.95, p.y) * (1.0 - smoothstep(0.2, 0.5, abs(p.x - 0.4)));
    } else {
        c = mix(vec3f(0.55, 0.22, 0.05), vec3f(0.05, 0.01, 0.0), band);
        c = mix(c, vec3f(1.0, 0.75, 0.4), holes(p, 0.06, 0.05));
        c = mix(c, vec3f(0.6, 0.25, 0.05), holes(p, 0.53, 0.06));
    }
    return c;
}

fn wash(p: vec2f, hot: bool) -> vec3f {
    let edge = 0.12 + 0.04 * sin(p.x * 18.8);
    let top = 1.0 - smoothstep(edge, edge + 0.12, p.y);
    var body = mix(vec3f(1.0, 0.75, 0.5), vec3f(0.85, 0.4, 0.2), smoothstep(0.1, 1.0, p.y + 0.3 * (1.0 - p.x)));
    if (hot) {
        body = mix(vec3f(1.0, 0.99, 0.93), vec3f(1.0, 0.9, 0.6), smoothstep(0.4, 1.2, p.y + 0.5 * (1.0 - p.x)));
    }
    return mix(body, vec3f(1.0), top);
}

fn burn(uv: vec2f, t: f32) -> vec3f {
    let frame_aspect = globals.size.x / globals.size.y;
    var p = uv;
    if (BURN_ASPECT > frame_aspect) { p.x = (p.x - 0.5) * (frame_aspect / BURN_ASPECT) + 0.5; }
    else { p.y = (p.y - 0.5) * (BURN_ASPECT / frame_aspect) + 0.5; }
    let look = burn_look(t);
    var c: vec3f;
    if (look.x < 0.5) { c = film_strip(p, false); }
    else if (look.x < 1.5) { c = film_strip(p, true); }
    else if (look.x < 2.5) { c = wash(p, false); }
    else { c = wash(p, true); }
    return clamp(c * look.y, vec3f(0.0), vec3f(1.0));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = START + clamp(params.progress, 0.0, 1.0) * LENGTH;
    var base: vec3f;
    if (t < SWAP) { base = textureSampleLevel(first, smp, uv, 0.0).rgb; }
    else { base = textureSampleLevel(second, smp, uv, 0.0).rgb; }
    let halo = clamp(textureSampleLevel(glow, smp, uv, 0.0).rgb * TINT * glow_gain(t), vec3f(0.0), vec3f(1.0));
    var c = 1.0 - (1.0 - clamp(base, vec3f(0.0), vec3f(1.0))) * (1.0 - halo);
    let o = flash_opacity(t);
    if (o > 0.0) { c = mix(c, burn(uv, t), o); }
    gpufx_write(id, vec4f(c, 1.0));
}
