// Frame planes -> rgba16float texture with straight alpha, before the first effect.

@group(0) @binding(1) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(2) var plane0: texture_2d<u32>;
@group(0) @binding(3) var plane1: texture_2d<u32>;
@group(0) @binding(4) var plane2: texture_2d<u32>;
@group(0) @binding(5) var plane3: texture_2d<u32>;

fn value(raw: u32) -> f32 {
    return f32(raw >> cv.shift);
}

fn luma(c: f32) -> f32 {
    if (cv.full != 0u) {
        return c / code_max();
    }
    return (c - 16.0 * code_scale()) / (219.0 * code_scale());
}

fn chroma(c: f32) -> f32 {
    if (cv.full != 0u) {
        return (c - f32(1u << (cv.depth - 1u))) / code_max();
    }
    return (c - 128.0 * code_scale()) / (224.0 * code_scale());
}

// U and V values of chroma sample p, clamped to the plane.
fn load_uv(p: vec2i) -> vec2f {
    let q = clamp(p, vec2i(0), vec2i(i32(cv.cwidth) - 1, i32(cv.cheight) - 1));
    if (cv.kind == 1u) {
        let t = textureLoad(plane1, q, 0);
        return vec2f(value(t.r), value(t.g));
    }
    return vec2f(value(textureLoad(plane1, q, 0).r), value(textureLoad(plane2, q, 0).r));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= cv.width || id.y >= cv.height) {
        return;
    }
    let p = vec2i(id.xy);
    var c: vec4f;
    if (cv.kind == 0u) {
        c = vec4f(textureLoad(plane0, p, 0)) / code_max();
    } else {
        let y = luma(value(textureLoad(plane0, p, 0).r));
        // Bilinear chroma: the fractional chroma sample under this pixel's centre.
        let sub = vec2f(f32(cv.sub_x), f32(cv.sub_y));
        let f = (vec2f(id.xy) - vec2f(cv.site_x, cv.site_y) * (sub - 1.0)) / sub;
        let i = floor(f);
        let w = f - i;
        let b = vec2i(i);
        let top = mix(load_uv(b), load_uv(b + vec2i(1, 0)), w.x);
        let bottom = mix(load_uv(b + vec2i(0, 1)), load_uv(b + vec2i(1, 1)), w.x);
        let uv = mix(top, bottom, w.y);
        let u = chroma(uv.x);
        let v = chroma(uv.y);
        let r = y + 2.0 * (1.0 - cv.kr) * v;
        let bl = y + 2.0 * (1.0 - cv.kb) * u;
        let g = (y - cv.kr * r - cv.kb * bl) / kg();
        var a = 1.0;
        if (cv.alpha != 0u) {
            a = value(textureLoad(plane3, p, 0).r) / code_max();
        }
        c = vec4f(r, g, bl, a);
    }
    c = clamp(c, vec4f(0.0), vec4f(1.0));
    if (cv.premul != 0u) {
        c = vec4f(select(vec3f(0.0), min(c.rgb / c.a, vec3f(1.0)), c.a > 0.0), c.a);
    }
    textureStore(dst, p, c);
}
