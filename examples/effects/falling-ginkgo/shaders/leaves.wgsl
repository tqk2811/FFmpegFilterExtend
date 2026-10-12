// Falling leaves drawn from a 2x2 atlas over the video.
//
// Stateless: every leaf is a pure function of (seed, slot, time), so seeking, dropped
// frames and split encodes all give the same picture. Each slot replays a fixed period;
// a new period is a new random leaf ("respawn"), and the switch always happens while the
// leaf is off screen. Units are frame heights: x in 0..aspect, y in 0..1 (down).
const MAX_LEAVES: u32 = 256u;
const GRID: vec2u = vec2u(2u, 2u);      // atlas cells
const SPEED_JITTER: f32 = 0.3;          // per-leaf fall speed in [1-j, 1+j] * speed
const TAU: f32 = 6.2831853;

struct Leaf {
    pos: vec2f,      // centre
    rot: vec2f,      // cos, sin of the angle
    scale: vec2f,    // sprite size (x shrinks when the leaf turns edge-on)
    cell: u32,       // atlas cell
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

fn make_leaf(i: u32, t: f32, aspect: f32) -> Leaf {
    var l: Leaf;
    l.alive = 0u;
    let speed = max(params.speed, 0.01);
    let margin = max(params.size.x, params.size.y) * 0.75; // half diagonal of the largest sprite
    let dist = 1.0 + 2.0 * margin;                  // above the top edge -> below the bottom
    // The period is fixed per slot and long enough for the slowest leaf, so the
    // generation is a pure function of t.
    let period = dist / (speed * (1.0 - SPEED_JITTER));
    let local = t + rnd(i, 0xffffffffu, 0u) * period;   // per-slot phase: full sky at t = 0
    let g = floor(local / period);                     // negative before t = 0 too
    let gen = bitcast<u32>(i32(g));
    let dur = dist / (speed * mix(1.0 - SPEED_JITTER, 1.0 + SPEED_JITTER, rnd(i, gen, 1u)));
    let tau = local - g * period - rnd(i, gen, 2u) * (period - dur);
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
    l.cell = min(u32(rnd(i, gen, 8u) * f32(GRID.x * GRID.y)), GRID.x * GRID.y - 1u);
    l.alive = 1u;
    return l;
}

// Premultiplied bilinear sample of one atlas cell, never reading the neighbouring cell.
// Done by hand because textures are straight alpha, which leaves dark fringes when the
// sampler filters it. uv is 0..1 inside the cell.
fn sample_cell(cell: u32, uv: vec2f) -> vec4f {
    let cell_px = vec2f(textureDimensions(atlas)) / vec2f(GRID);
    let origin = vec2f(f32(cell % GRID.x), f32(cell / GRID.x)) * cell_px;
    let p = origin + uv * cell_px - 0.5;
    let lo = vec2i(floor(p));
    let f = p - floor(p);
    let mn = vec2i(origin);
    let mx = vec2i(origin + cell_px) - 1;
    var acc = vec4f(0.0);
    for (var k = 0; k < 4; k++) {
        let o = vec2i(k & 1, k >> 1);
        let c = textureLoad(atlas, clamp(lo + o, mn, mx), 0);
        let wt = select(1.0 - f.x, f.x, o.x == 1) * select(1.0 - f.y, f.y, o.y == 1);
        acc += vec4f(c.rgb * c.a, c.a) * wt;
    }
    return acc;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u, @builtin(local_invocation_index) li: u32) {
    let aspect = globals.size.x / globals.size.y;
    let t = globals.time + params.offset;
    let n = min(u32(max(params.count, 0)), MAX_LEAVES);
    // The 64 threads of the workgroup build the leaves once, instead of every pixel
    // building all of them. The barrier needs uniform control flow, so the bounds check
    // comes after it.
    for (var i = li; i < n; i += 64u) { leaves[i] = make_leaf(i, t, aspect); }
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
        let c = sample_cell(l.cell, q + 0.5) * params.opacity;
        acc = c + acc * (1.0 - c.a);
        hit = hit || c.a > 0.0;
    }
    // Untouched pixels pass through as they are, colour of transparent pixels included.
    if (!hit) { gpufx_write(id, base); return; }
    gpufx_write(id, vec4f(select(vec3f(0.0), acc.rgb / acc.a, acc.a > 0.0), acc.a));
}
