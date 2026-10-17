// A giant cherry blossom petal sweeps across the frame among drifting petals, flipping over as a soft wipe reveals the second clip.

// Length of the animation timeline in seconds.
const SPAN: f32 = 2.0;
// Frame rate the petal motion was laid out at.
const FPS: f32 = 30.0;
// First keyed frame of the big petal; the tables below hold one entry per frame from here on.
const BIG_FIRST: f32 = 20.0;
// Frame from which the big petal shows its back side.
const BIG_BACK: f32 = 44.0;
// Number of small drifting petals.
const SPECKS: i32 = 90;

// Big petal per frame: centre (square petal space, y down), half length, half width.
const BIG_SHAPE = array<vec4f, 33>(
    vec4f(1.13, 0.20, 0.12, 0.07), vec4f(1.06, 0.26, 0.12, 0.10), vec4f(0.96, 0.25, 0.12, 0.08),
    vec4f(0.96, 0.25, 0.20, 0.09), vec4f(0.97, 0.30, 0.20, 0.155), vec4f(0.94, 0.33, 0.20, 0.19),
    vec4f(0.96, 0.34, 0.28, 0.202), vec4f(0.96, 0.35, 0.32, 0.225), vec4f(0.97, 0.35, 0.39, 0.235),
    vec4f(0.94, 0.37, 0.39, 0.245), vec4f(0.94, 0.37, 0.45, 0.255), vec4f(0.945, 0.37, 0.495, 0.265),
    vec4f(0.945, 0.38, 0.535, 0.288), vec4f(0.945, 0.375, 0.575, 0.298), vec4f(0.925, 0.385, 0.60, 0.303),
    vec4f(0.91, 0.38, 0.65, 0.303), vec4f(0.91, 0.37, 0.69, 0.303), vec4f(0.69, 0.47, 0.54, 0.22),
    vec4f(0.57, 0.53, 0.48, 0.16), vec4f(0.51, 0.59, 0.54, 0.145), vec4f(0.48, 0.56, 0.54, 0.13),
    vec4f(0.42, 0.56, 0.51, 0.085), vec4f(0.36, 0.56, 0.51, 0.055), vec4f(0.30, 0.53, 0.45, 0.025),
    vec4f(0.22, 0.57, 0.45, 0.0), vec4f(0.15, 0.615, 0.46, 0.03), vec4f(0.08, 0.685, 0.55, 0.065),
    vec4f(0.075, 0.585, 0.455, 0.065), vec4f(0.035, 0.675, 0.455, 0.075), vec4f(0.035, 0.67, 0.365, 0.055),
    vec4f(0.035, 0.695, 0.295, 0.03), vec4f(0.015, 0.75, 0.33, 0.06), vec4f(-0.06, 0.8, 0.35, 0.0));
// Big petal per frame: direction from the broad end to the tip, degrees (0 = right, 90 = down).
const BIG_TURN = array<f32, 33>(
    110.0, 110.0, 113.0, 143.0, 160.0, 164.0, 152.0, 155.0, 152.0, 149.0, 148.0, 148.0, 148.0, 147.0,
    145.0, 142.0, 142.0, 128.0, 116.0, 110.0, 110.0, 104.0, 104.0, 104.0, 102.0, 100.0, 98.0, 92.0,
    92.0, 89.0, 89.0, 89.0, 89.0);

// Straight-alpha colour of one petal surface.
struct Paint {
    rgb: vec3f,
    a: f32,
}

fn hash11(n: f32) -> f32 { return fract(sin(n * 127.1) * 43758.5453); }

// Egg-shaped petal outline: coverage and position along (s, -1 broad .. 1 tip) / across (w) the petal.
fn petal_cover(p: vec2f, centre: vec2f, turn: f32, half_len: f32, half_wid: f32, soft: f32) -> vec3f {
    if (half_wid <= 0.0) { return vec3f(0.0); }
    let dir = vec2f(cos(radians(turn)), sin(radians(turn)));
    let d = p - centre;
    let s = dot(d, dir) / half_len;
    let w = (dir.x * d.y - dir.y * d.x) / half_wid;
    let edge = sqrt(max(1.0 - s * s, 0.0)) * (1.15 - 0.35 * s) + 0.03 * sin(s * 19.0);
    let inside_w = (edge - abs(w)) * half_wid;
    let inside_s = (1.0 - abs(s)) * half_len;
    let cover = smoothstep(-soft, soft, min(inside_w, inside_s));
    return vec3f(cover, s, w / max(edge, 0.05));
}

fn big_petal(p: vec2f, frame: f32) -> Paint {
    var out: Paint;
    out.a = 0.0;
    out.rgb = vec3f(0.0);
    let x = frame - BIG_FIRST;
    if (x < 0.0 || x >= 32.0) { return out; }
    let i = u32(floor(x));
    let f = fract(x);
    let shape = mix(BIG_SHAPE[i], BIG_SHAPE[i + 1u], f);
    let turn = mix(BIG_TURN[i], BIG_TURN[i + 1u], f);
    let c = petal_cover(p, shape.xy, turn, shape.z, shape.w, 0.004);
    if (c.x <= 0.0) { return out; }
    let s = c.y;
    let w = c.z;
    var rgb: vec3f;
    if (frame < BIG_BACK) {
        // Front face: pale centre, deeper pink along one side, creamy near the tip.
        rgb = vec3f(0.97, 0.89, 0.93);
        rgb = mix(rgb, vec3f(0.84, 0.60, 0.67), smoothstep(0.1, 0.95, w));
        rgb = mix(rgb, vec3f(0.92, 0.79, 0.85), smoothstep(-0.1, -0.95, w));
        rgb = mix(rgb, vec3f(0.96, 0.96, 0.88), smoothstep(0.55, 1.0, s));
    } else {
        // Back face: a flatter, rosier pink that lightens toward the tip.
        rgb = mix(vec3f(0.86, 0.62, 0.70), vec3f(0.94, 0.86, 0.88), smoothstep(-0.8, 0.9, s));
    }
    out.rgb = rgb;
    out.a = c.x;
    return out;
}

// Medium petal tumbling along the top edge during the opening frames.
fn top_petal(p: vec2f, frame: f32) -> Paint {
    var out: Paint;
    out.a = 0.0;
    out.rgb = vec3f(0.0);
    if (frame >= 14.0) { return out; }
    let centre = vec2f(0.88 - 0.077 * frame, 0.045 + 0.006 * frame);
    let c = petal_cover(p, centre, 20.0 + 8.0 * sin(frame * 0.6), 0.10, 0.06 * (0.8 + 0.2 * cos(frame * 0.9)), 0.005);
    out.rgb = mix(vec3f(0.95, 0.80, 0.88), vec3f(0.99, 0.97, 0.97), smoothstep(-0.5, 0.8, c.z));
    out.a = c.x;
    return out;
}

// How many of the small petals are out at time t (seconds), 0..1.
fn speck_density(t: f32) -> f32 {
    return (0.35 + 0.65 * smoothstep(0.0, 1.15, t)) * (1.0 - smoothstep(1.45, 1.9, t));
}

// Small petals blowing leftward across the upper part of the frame.
fn specks(p: vec2f, t: f32) -> Paint {
    var out: Paint;
    out.a = 0.0;
    out.rgb = vec3f(0.0);
    let density = speck_density(t);
    if (density <= 0.0) { return out; }
    for (var j = 0; j < SPECKS; j++) {
        let n = f32(j);
        if (hash11(n + 0.13) > density) { continue; }
        let speed = vec2f(-0.30 - 0.35 * hash11(n + 1.7), 0.04 + 0.12 * hash11(n + 2.9));
        var pos = vec2f(hash11(n + 3.1) * 1.6 - 0.1, hash11(n + 4.7) * 0.85 - 0.05) + speed * t;
        pos.x = fract(pos.x / 1.4 + 1.0) * 1.4 - 0.2;
        let size = 0.006 + 0.012 * hash11(n + 5.3) * hash11(n + 6.1);
        if (length(p - pos) > size * 1.5 + 0.003) { continue; }
        let spin = hash11(n + 7.9) * 360.0 + t * 400.0 * (hash11(n + 8.3) - 0.5);
        let c = petal_cover(p, pos, spin, size, size * (0.35 + 0.35 * abs(sin(t * 6.0 + n))), 0.0025);
        if (c.x > 0.0) {
            let tint = mix(vec3f(0.97, 0.80, 0.88), vec3f(1.0, 0.98, 0.98), hash11(n + 9.7));
            out.rgb = mix(out.rgb, tint, c.x);
            out.a = max(out.a, c.x);
        }
    }
    return out;
}

// Map the output pixel into the square petal space, filling the frame and cropping the overflow.
fn petal_space(uv: vec2f, aspect: f32) -> vec2f {
    if (aspect >= 1.0) { return vec2f(uv.x, 0.5 + (uv.y - 0.5) / aspect); }
    return vec2f(0.5 + (uv.x - 0.5) * aspect, uv.y);
}

fn over(dst: vec3f, src: Paint) -> vec3f { return mix(dst, src.rgb, src.a); }

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so the cut into and out of the transition is seamless.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = params.progress * SPAN;
    let outgoing = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let incoming = textureSampleLevel(second, smp, uv, 0.0).rgb;

    // Soft vertical wipe that brings the second clip in from the right edge.
    let x = clamp((t - 1.166667) / 0.133333, 0.0, 1.0);
    let y = clamp((t - 1.3) / 0.3, 0.0, 1.0);
    var wipe = 1.36;
    if (t >= 1.166667) { wipe = select(mix(1.36, 0.730769, x), mix(0.730769, -0.5, y), t >= 1.3); }
    let reveal = smoothstep(wipe - 0.34, wipe + 0.34, uv.x);
    var colour = mix(outgoing, incoming, reveal);
    if (t >= 1.6) { colour = incoming; }

    // Petals drawn on top.
    let dims = globals.size;
    let p = petal_space(uv, dims.x / dims.y);
    let frame = t * FPS;
    colour = over(colour, specks(p, t));
    colour = over(colour, top_petal(p, frame));
    colour = over(colour, big_petal(p, frame));
    gpufx_write(id, vec4f(colour, 1.0));
}
