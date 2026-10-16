// Big wave, step 2: zoom blur toward the centre whose far taps fade out.

const TIMELINE: f32 = 0.8333333;
const SWITCH_AT: f32 = 0.366667;
const TAU: f32 = 6.2831853;

fn timeline_now() -> f32 { return clamp(params.progress, 0.0, 1.0) * TIMELINE; }

// CSS-like cubic-bezier easing through (0,0) (x1,y1) (x2,y2) (1,1), solved for x by bisection.
fn bezier_axis(a: f32, b: f32, s: f32) -> f32 {
    let r = 1.0 - s;
    return 3.0 * a * r * r * s + 3.0 * b * r * s * s + s * s * s;
}

fn ease(x1: f32, y1: f32, x2: f32, y2: f32, u: f32) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 22; i++) {
        let mid = 0.5 * (lo + hi);
        if (bezier_axis(x1, x2, mid) > u) { hi = mid; } else { lo = mid; }
    }
    return bezier_axis(y1, y2, 0.5 * (lo + hi));
}

// One keyframe segment: keeps `cur` before `t0`, eases from v0 to v1 inside, holds v1 after.
fn key(cur: f32, t: f32, t0: f32, t1: f32, v0: f32, v1: f32, e: vec4f) -> f32 {
    if (t < t0) { return cur; }
    if (t >= t1) { return v1; }
    return mix(v0, v1, ease(e.x, e.y, e.z, e.w, (t - t0) / (t1 - t0)));
}

const LINEAR = vec4f(0.1666667, 0.1666667, 0.8333333, 0.8333333);

fn zoom_now(t: f32) -> f32 {
    if (t < SWITCH_AT) {
        return key(0.0, t, 0.0, 0.366667, 0.0, 33.0, vec4f(0.42, 0.0, 0.999, 1.0)) / 200.0;
    }
    return key(88.0, t, 0.366667, 0.7, 88.0, 0.0, vec4f(0.001, 0.0, 0.58, 1.0)) / 200.0;
}

fn jitter(p: vec2f) -> f32 {
    let f = fract(p * 13.517);
    let g = f + vec2f(dot(f, f.yx + vec2f(22.541)));
    return fract((g.x + g.y) * g.y);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let amount = zoom_now(timeline_now());
    var acc = textureSampleLevel(bent, smp, uv, 0.0);
    if (amount > 0.0) {
        let reach = (uv - vec2f(0.5)) * amount;
        let taps = min(80.0 * (0.9 * length(reach) + 0.1) + 5.0, 128.0);
        let stride = reach / taps;
        // Over the whole tap run the weight falls to 0.965^50.
        let fade = pow(pow(0.965, 50.0), 1.0 / taps);
        let start = uv + stride * 0.5 * (jitter(uv) * 2.0 - 1.0);
        var weight = 1.0;
        var total = 1.0;
        for (var k = 1.0; k <= 128.0; k += 1.0) {
            if (k > taps) { break; }
            weight *= fade;
            let q = start - stride * k;
            total += weight;
            if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
                acc += textureSampleLevel(bent, smp, q, 0.0) * weight;
            }
        }
        acc /= total;
    }
    gpufx_write(id, vec4f(acc.rgb, 1.0));
}
