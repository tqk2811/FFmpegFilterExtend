// Doorway: the first clip parts down the middle and swings open as the second one approaches.

// Strength of the floor reflection under the incoming clip.
const MIRROR_STRENGTH: f32 = 0.4;
// How much the far edge of each door shrinks vertically as it swings.
const DOOR_TILT: f32 = 0.4;
// Starting distance of the incoming clip: it begins at 1/3 of its final size.
const START_DISTANCE: f32 = 3.0;

// With `overlap` off, only one clip feeds the transition at a time: the first clip for
// the first half of `progress`, the second clip for the rest, in both roles.
fn outgoing_tex_is_second() -> bool {
    return params.overlap == 0u && params.progress >= 0.5;
}

fn incoming_tex_is_first() -> bool {
    return params.overlap == 0u && params.progress < 0.5;
}

fn inside_frame(q: vec2f) -> bool {
    return all(q > vec2f(0.0)) && all(q < vec2f(1.0));
}

// Coordinates below run with y pointing up; flip back before sampling.
fn read_first(q: vec2f) -> vec4f {
    let p = vec2f(q.x, 1.0 - q.y);
    if (outgoing_tex_is_second()) { return textureSampleLevel(second, smp, p, 0.0); }
    return textureSampleLevel(first, smp, p, 0.0);
}

fn read_second(q: vec2f) -> vec4f {
    let p = vec2f(q.x, 1.0 - q.y);
    if (incoming_tex_is_first()) { return textureSampleLevel(first, smp, p, 0.0); }
    return textureSampleLevel(second, smp, p, 0.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let q = vec2f(uv.x, 1.0 - uv.y);
    let dark = vec4f(0.0, 0.0, 0.0, 1.0);

    // Door coordinates: distance from the centre line minus the opening width. Pixels
    // still covered by a door shift outward by half the opening and get squeezed
    // vertically more the closer they are to the inner (moving) edge.
    var door = vec2f(-1.0);
    let cover = 2.0 * abs(q.x - 0.5) - t;
    if (cover >= 0.0) {
        let outward = select(1.0, -1.0, q.x > 0.5);
        door = q + vec2f(outward * 0.5 * t, 0.0);
        let squeeze = 1.0 / (1.0 + DOOR_TILT * t * (1.0 - cover));
        door.y = (door.y - squeeze * 0.5) * squeeze + squeeze * 0.5;
    }

    // Incoming clip scaled about the centre, from START_DISTANCE down to 1.
    let distance = mix(1.0, START_DISTANCE, 1.0 - t);
    let room = (q - 0.5) * distance + 0.5;

    var color = dark;
    if (inside_frame(door)) {
        color = read_first(door);
    } else if (inside_frame(room)) {
        color = read_second(room);
    } else {
        // Mirror the incoming clip below itself, stretched a little and fading downward.
        let floor_q = room * vec2f(1.0, -1.2) + vec2f(0.0, -0.02);
        if (inside_frame(floor_q)) {
            color = dark + mix(dark, read_second(floor_q), MIRROR_STRENGTH * (1.0 - floor_q.y));
        }
    }
    gpufx_write(id, vec4f(color.rgb, 1.0));
}
