// Falling leaves drawn over the video from `sprites`, a texture array cut from a 2x2
// atlas, with mipmaps and premultiplied alpha made when the package loads.
//
// Stateless: every leaf is a pure function of (seed, slot, time), so seeking, dropped
// frames and split encodes all give the same picture. Each slot replays a fixed period;
// a new period is a new random leaf ("respawn"), and the switch always happens while the
// leaf is off screen. Units are frame heights: x in 0..aspect, y in 0..1 (down).
const MAX_LEAVES: u32 = 256u;
const SPEED_JITTER: f32 = 0.3;          // per-leaf fall speed in [1-j, 1+j] * speed
const TAU: f32 = 6.2831853;
const TICKS: f32 = 64.0;                // time steps per second of the slot clocks

struct Leaf {
    pos: vec2f,      // centre
    rot: vec2f,      // cos, sin of the angle
    scale: vec2f,    // sprite size (x shrinks when the leaf turns edge-on)
    lod: f32,        // mip level: sprite texels per screen pixel, as a power of two
    layer: u32,      // which leaf picture
    alpha: f32,      // fades custom paths in and out
    alive: u32,
};

var<workgroup> leaves: array<Leaf, MAX_LEAVES>;

fn hash_u(v: vec4u) -> u32 {
    var x = v.x * 1664525u + v.y * 22695477u + v.z * 2654435761u + v.w * 340573321u + 1013904223u;
    x = x ^ (x >> 16u); x = x * 2246822519u;
    x = x ^ (x >> 13u); x = x * 3266489917u;
    return x ^ (x >> 16u);
}

// k-th random number in [0,1) of (slot, generation).
fn rnd(slot: u32, gen: u32, k: u32) -> f32 {
    return f32(hash_u(vec4u(u32(params.seed), slot, gen, k)) >> 8u) / 16777216.0;
}

// The time as whole ticks and the fraction of a tick, from the exact whole seconds and
// fraction in globals: f32 seconds would make leaves stutter hours into a clip. The i32
// tick count wraps after about 388 days, which shows as one jump of the leaves.
struct Clock {
    ticks: i32,
    sub: f32,
};

fn clock() -> Clock {
    let off_s = floor(params.offset);
    let f = (globals.time_frac + params.offset - off_s) * TICKS;   // 0 .. 2 * TICKS
    let fi = floor(f);
    return Clock((globals.time_int + i32(off_s)) * i32(TICKS) + i32(fi), f - fi);
}

// Sprite size, picture and mip level of a leaf, the same in every mode.
fn dress(l: ptr<function, Leaf>, i: u32, gen: u32, size: f32) {
    let pictures = textureNumLayers(sprites);
    (*l).layer = min(u32(rnd(i, gen, 8u) * f32(pictures)), pictures - 1u);
    // Compute shaders have no derivatives: the level comes from the drawn size, once per leaf.
    let texels = f32(textureDimensions(sprites).y);
    (*l).lod = clamp(log2(texels / max(size * globals.size.y, 1e-3)), 0.0, f32(textureNumLevels(sprites) - 1u));
}

// Mode 4: the path comes from the path_x, path_y and angle expressions of the command
// line, compiled into this shader. Every leaf lives `life` seconds, then respawns.
fn make_custom(i: u32, now: Clock, aspect: f32) -> Leaf {
    var l: Leaf;
    l.alive = 0u;
    let pt = max(i32(ceil(max(params.life, 0.1) * TICKS)), 1);
    let local = now.ticks + i32(rnd(i, 0xffffffffu, 0u) * f32(pt));
    var g = local / pt;
    var r = local - g * pt;
    if (r < 0) { r += pt; g -= 1; }
    let gen = bitcast<u32>(g);
    let u = (f32(r) + now.sub) / TICKS;               // seconds since the leaf appeared
    let p = u * TICKS / f32(pt);                      // 0..1 over its life
    let t = globals.time + params.offset;
    let fi = f32(i);
    let r0 = rnd(i, gen, 10u);
    let r1 = rnd(i, gen, 11u);
    let r2 = rnd(i, gen, 12u);
    let r3 = rnd(i, gen, 13u);
    let x0 = rnd(i, gen, 6u) * aspect;
    let pos = vec2f(gpufx_expr_path_x(t, u, p, fi, r0, r1, r2, r3, x0, aspect, 1.0),
                    gpufx_expr_path_y(t, u, p, fi, r0, r1, r2, r3, x0, aspect, 1.0));
    let ang = radians(gpufx_expr_angle(t, u, p, fi, r0, r1, r2, r3, x0, aspect, 1.0));
    // NaN or far away (log of a negative number, division by zero): not drawn.
    if (!(abs(pos.x) < 1e4 && abs(pos.y) < 1e4 && abs(ang) < 1e7)) { return l; }
    let depth = (fi + rnd(i, gen, 3u)) / f32(max(params.count, 1));
    let size = mix(params.size.x, params.size.y, depth);
    l.pos = pos;
    l.rot = vec2f(cos(ang), sin(ang));
    l.scale = vec2f(size, size);
    dress(&l, i, gen, size);
    l.alpha = clamp(min(p / 0.05, (1.0 - p) / 0.15), 0.0, 1.0);   // no pop in or out
    l.alive = 1u;
    return l;
}

fn make_leaf(i: u32, now: Clock, aspect: f32) -> Leaf {
    if (params.mode == 4) { return make_custom(i, now, aspect); }
    var l: Leaf;
    l.alive = 0u;
    let speed = max(params.speed, 0.01);
    let margin = max(params.size.x, params.size.y) * 0.75; // half diagonal of the largest sprite
    let dist = 1.0 + 2.0 * margin;                  // above the top edge -> below the bottom
    // The period is fixed per slot, a whole number of ticks long enough for the slowest
    // leaf, so the generation is a pure function of the time, counted in integers.
    let pt = i32(ceil(dist / (speed * (1.0 - SPEED_JITTER)) * TICKS));
    let period = f32(pt) / TICKS;
    // Per-slot phase: full sky at t = 0.
    let local = now.ticks + i32(rnd(i, 0xffffffffu, 0u) * f32(pt));
    var g = local / pt;                               // negative before t = 0 too
    var r = local - g * pt;
    if (r < 0) { r += pt; g -= 1; }
    let gen = bitcast<u32>(g);
    let dur = dist / (speed * mix(1.0 - SPEED_JITTER, 1.0 + SPEED_JITTER, rnd(i, gen, 1u)));
    let tau = (f32(r) + now.sub) / TICKS - rnd(i, gen, 2u) * (period - dur);
    if (tau < 0.0 || tau > dur) { return l; }

    // Slot order is depth order: later slots are nearer, bigger and drawn on top.
    let depth = (f32(i) + rnd(i, gen, 3u)) / f32(max(params.count, 1));
    let s = mix(params.size.x, params.size.y, depth);
    let ph = rnd(i, gen, 4u) * TAU;
    let freq = mix(0.6, 1.4, rnd(i, gen, 5u));
    let dir = select(-1.0, 1.0, rnd(i, gen, 7u) < 0.5);   // spin direction
    let w = freq * TAU * 0.5 * tau + ph;                   // sway / spiral phase
    // Start anywhere the wind can carry the leaf into the frame from.
    let drift = params.wind * dur;
    let x0 = rnd(i, gen, 6u) * (aspect + 2.0 * margin + abs(drift)) - margin - max(drift, 0.0);

    var x = x0 + params.wind * tau;
    var ang = ph;
    var turn = max(abs(cos(freq * 2.0 * tau + ph)), 0.2); // edge-on flip
    var size = s;
    switch (params.mode) {
        case 1: {   // swing like a pendulum under a slow side-to-side drift
            x += params.sway * sin(w);
            ang = (rnd(i, gen, 9u) - 0.5) * 0.6 + 0.9 * sin(w + 1.5707963);   // stem stays up
            turn = 1.0;
        }
        case 2: {   // spiral round a falling axis, nearer on one side
            x += params.sway * sin(w);
            size *= 0.85 + 0.15 * cos(w);
            ang += dir * params.spin * tau;
            turn = max(abs(cos(w)), 0.3);
        }
        case 3: {   // no swing, turning slowly (the wind still drifts it)
            ang += dir * params.spin * 0.3 * tau;
            turn = 1.0;
        }
        default: {  // tumble: spin round and round while the wind carries it
            x += params.sway * sin(w);
            ang += dir * params.spin * tau;
        }
    }
    l.pos = vec2f(x, -margin + dist * tau / dur);
    l.rot = vec2f(cos(ang), sin(ang));
    l.scale = vec2f(size * turn, size);
    dress(&l, i, gen, size);
    l.alpha = 1.0;
    l.alive = 1u;
    return l;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u, @builtin(local_invocation_index) li: u32) {
    let aspect = globals.size.x / globals.size.y;
    let now = clock();
    let n = min(u32(max(params.count, 0)), MAX_LEAVES);
    // The 64 threads of the workgroup build the leaves once, instead of every pixel
    // building all of them. The barrier needs uniform control flow, so the bounds check
    // comes after it.
    for (var i = li; i < n; i += 64u) { leaves[i] = make_leaf(i, now, aspect); }
    workgroupBarrier();
    if (!gpufx_in_bounds(id)) { return; }

    let base = textureLoad(src, vec2i(id.xy), 0);
    var acc = vec4f(base.rgb * base.a, base.a);     // premultiplied
    var hit = false;
    let p = (vec2f(id.xy) + 0.5) / globals.size.y;
    for (var i = 0u; i < n; i++) {
        let l = leaves[i];
        if (l.alive == 0u) { continue; }
        let d = p - l.pos;
        if (dot(d, d) > 0.5 * l.scale.y * l.scale.y) { continue; }  // outside the bounding circle
        let q = vec2f(l.rot.x * d.x + l.rot.y * d.y, -l.rot.y * d.x + l.rot.x * d.y) / l.scale;
        if (any(abs(q) > vec2f(0.5))) { continue; }
        let c = textureSampleLevel(sprites, smp, q + 0.5, l.layer, l.lod) * (params.opacity * l.alpha);  // premultiplied
        acc = c + acc * (1.0 - c.a);
        hit = hit || c.a > 0.0;
    }
    // Untouched pixels pass through as they are, colour of transparent pixels included.
    if (!hit) { gpufx_write(id, base); return; }
    gpufx_write(id, vec4f(select(vec3f(0.0), acc.rgb / acc.a, acc.a > 0.0), acc.a));
}
