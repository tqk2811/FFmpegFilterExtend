// A burst of glittering sparks bursts out of the centre, then snowflakes drift and fade over the second clip.

// The transition runs over 50 animation frames (2 s at 25 fps).
const FRAMES: f32 = 50.0;
const PI: f32 = 3.14159265;
// Sparks thrown out by the initial burst.
const SPARKS: i32 = 110;
// Flakes, rings and dots that float after the burst.
const FLAKES: i32 = 120;

fn hash(n: f32) -> f32 {
    return fract(sin(n * 91.3458) * 47453.5453);
}

// Six-armed snowflake of radius 1 in local coordinates; returns the distance to its strokes.
fn flake_dist(q: vec2f) -> f32 {
    let r = length(q);
    let sector = PI / 3.0;
    var a = atan2(q.y, q.x);
    a = abs(a - sector * round(a / sector));
    let p = vec2f(cos(a), sin(a)) * r;
    // Main arm along +x.
    var d = select(length(p - vec2f(1.0, 0.0)), p.y, p.x <= 1.0 && p.x >= 0.0);
    // Two side twigs leaning outwards at 60 degrees.
    for (var k = 0; k < 2; k++) {
        let base = vec2f(0.45 + 0.25 * f32(k), 0.0);
        let tip = base + vec2f(0.5, 0.866) * (0.34 - 0.1 * f32(k));
        let ab = tip - base;
        let h = clamp(dot(p - base, ab) / dot(ab, ab), 0.0, 1.0);
        d = min(d, length(p - base - ab * h));
    }
    return d;
}

// Brightness of one particle at `q` (local units), kind 0 = flake, 1 = ring, 2 = dot.
fn particle(q: vec2f, kind: f32, aa: f32, haze: f32) -> f32 {
    let r = length(q);
    if (r > 3.0) { return 0.0; }
    var d: f32;
    var w: f32;
    if (kind < 0.5) {
        d = flake_dist(q);
        w = 0.07;
    } else if (kind < 1.5) {
        d = abs(r - 0.75);
        w = 0.1;
    } else {
        d = r;
        w = 0.45;
    }
    let edge = w + aa + haze;
    let core = 1.0 - smoothstep(w - aa, edge, d);
    let glow = exp(-d * 3.0) * 0.35;
    return max(core * (1.0 - 0.5 * haze), glow);
}

fn snow(c: vec2f, aa_unit: f32, f: f32) -> f32 {
    var total = 0.0;

    // Burst: sparks travel outwards on rays, streaking while fast.
    let burst_fade = smoothstep(0.0, 1.0, f) * (1.0 - smoothstep(5.0, 12.0, f));
    if (burst_fade > 0.0) {
        let reach = 0.1 * f + 0.0125 * f * f;
        let speed = 0.1 + 0.025 * f;
        // Soft ball of light behind the young burst.
        let r = length(c);
        total += exp(-r * r / max(0.4 * reach * reach, 1e-5)) * 0.55 * (1.0 - smoothstep(2.0, 5.0, f));
        for (var i = 0; i < SPARKS; i++) {
            let n = f32(i);
            let ang = hash(n + 1.0) * 2.0 * PI;
            let depth = 0.15 + 0.85 * sqrt(hash(n + 11.0));
            let dir = vec2f(cos(ang), sin(ang));
            let centre = dir * depth * reach;
            let size = (0.006 + 0.012 * hash(n + 23.0)) * (0.6 + 1.2 * depth * reach + 0.2);
            let stretch = 1.0 + depth * speed * 40.0 * (0.4 + hash(n + 37.0));
            let rel = c - centre;
            let along = dot(rel, dir) / stretch;
            let across = dot(rel, vec2f(-dir.y, dir.x));
            let q = vec2f(along, across) / size;
            total += particle(q, 2.0, aa_unit / size, 0.0) * (0.55 + 0.45 * hash(n + 41.0)) * burst_fade;
        }
    }

    // Floating flakes: rush in from the camera, settle and drift, then fade out.
    let appear = smoothstep(2.5, 5.0, f);
    let fade = pow(clamp(1.0 - (f - 8.0) / 38.0, 0.0, 1.0), 1.6);
    let float_fade = appear * fade;
    if (float_fade > 0.0) {
        let since = max(f - 2.5, 0.0);
        let zoom = 1.0 + 3.0 * exp(-since / 2.5);
        for (var i = 0; i < FLAKES; i++) {
            let n = f32(i) + 200.0;
            let home = vec2f(hash(n + 3.0), hash(n + 5.0)) * 1.2 - 0.6;
            let drift = vec2f(hash(n + 7.0) - 0.7, hash(n + 9.0) - 0.7) * 0.004;
            let centre = home * zoom + drift * since;
            let pick = hash(n + 13.0);
            var kind = 2.0;
            var size = 0.004 + 0.006 * hash(n + 17.0);
            if (pick < 0.35) {
                kind = 0.0;
                size = 0.022 + 0.04 * hash(n + 17.0) * hash(n + 19.0);
            } else if (pick < 0.5) {
                kind = 1.0;
                size = 0.006 + 0.004 * hash(n + 17.0);
            }
            size *= zoom;
            let haze = clamp((zoom - 1.0) * 0.25, 0.0, 0.5);
            let q = (c - centre) / size;
            total += particle(q, kind, aa_unit / size, haze) * (0.6 + 0.4 * hash(n + 29.0)) * float_fade;
        }
    }
    return clamp(total, 0.0, 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let p = clamp(params.progress, 0.0, 1.0);
    // Exact clips at the ends, so the transition joins the cut seamlessly.
    if (p <= 0.0) {
        gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    if (p >= 1.0) {
        gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0));
        return;
    }
    let f = p * FRAMES;
    let outgoing = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let incoming = textureSampleLevel(second, smp, uv, 0.0).rgb;
    // The first clip fades out over the second during frames 2..4.
    let base = mix(outgoing, incoming, clamp((f - 2.0) / 2.0, 0.0, 1.0));

    // Square snow layer covering the frame, centred, sized by the longer side.
    let side = max(globals.size.x, globals.size.y);
    let c = (uv - 0.5) * globals.size / side;
    let light = snow(c, 1.0 / side, f);
    let color = 1.0 - (1.0 - base) * (1.0 - light);
    gpufx_write(id, vec4f(color, 1.0));
}
