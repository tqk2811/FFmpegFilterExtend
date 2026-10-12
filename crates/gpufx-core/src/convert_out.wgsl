// RGBA result -> one plane of the output frame. Shared by convert_out_buffer.wgsl
// (frames read back to the CPU) and convert_out_image.wgsl (frames staying on the GPU).

@group(0) @binding(1) var src: texture_2d<f32>;

// Pixel p of the result, clamped to the frame, premultiplied when the output wants it.
fn fetch(p: vec2i) -> vec4f {
    let q = clamp(p, vec2i(0), vec2i(i32(cv.width) - 1, i32(cv.height) - 1));
    var c = clamp(textureLoad(src, q, 0), vec4f(0.0), vec4f(1.0));
    if (cv.premul != 0u) {
        c = vec4f(c.rgb * c.a, c.a);
    }
    return c;
}

fn yuv(c: vec3f) -> vec3f {
    let y = cv.kr * c.r + kg() * c.g + cv.kb * c.b;
    return vec3f(y, (c.b - y) / (2.0 * (1.0 - cv.kb)), (c.r - y) / (2.0 * (1.0 - cv.kr)));
}

// Y, U, V, A (R, G, B, A for RGB formats) of sample s of the plane, before encoding.
fn sample(s: vec2u) -> vec4f {
    if (cv.chroma == 0u) {
        let c = fetch(vec2i(s));
        if (cv.kind == 0u) {
            return c;
        }
        return vec4f(yuv(c.rgb), c.a);
    }
    // Triangle filter over the pixels around the chroma sample: the transpose of the
    // bilinear upsampling of convert_in ([1 3 3 1] centred, [1 2 1] co-sited).
    let sub = vec2f(f32(cv.sub_x), f32(cv.sub_y));
    let pos = sub * vec2f(s) + 0.5 + vec2f(cv.site_x, cv.site_y) * (sub - 1.0);
    let base = vec2i(floor(pos));
    var sum = vec3f(0.0);
    var total = 0.0;
    for (var j = -2; j <= 1; j++) {
        for (var i = -2; i <= 1; i++) {
            let k = base + vec2i(i, j);
            let d = abs(vec2f(k) + 0.5 - pos) / sub;
            let w = max(1.0 - d.x, 0.0) * max(1.0 - d.y, 0.0);
            if (w > 0.0) {
                sum += w * yuv(fetch(k).rgb);
                total += w;
            }
        }
    }
    return vec4f(sum / total, 1.0);
}

fn encode(v: f32, ch: u32) -> u32 {
    let m = code_max();
    var c = v * m;
    if (cv.kind != 0u && ch != 3u) {
        if (cv.full != 0u) {
            if (ch != 0u) {
                c = v * m + f32(1u << (cv.depth - 1u));
            }
        } else if (ch == 0u) {
            c = (v * 219.0 + 16.0) * code_scale();
        } else {
            c = (v * 224.0 + 128.0) * code_scale();
        }
    }
    return u32(clamp(round(c), 0.0, m)) << cv.shift;
}

fn channel(i: u32) -> u32 {
    switch i {
        case 0u: { return cv.ch0; }
        case 1u: { return cv.ch1; }
        case 2u: { return cv.ch2; }
        default: { return cv.ch3; }
    }
}
