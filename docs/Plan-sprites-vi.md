# Kế hoạch: ảnh sprite trong gói hiệu ứng (ví dụ lá rơi)

> Trạng thái: kế hoạch, chưa triển khai. Ngày: 2026-10-12.

## 1. Câu hỏi và trả lời ngắn

**Yêu cầu:** đặt vài ảnh lá vào zip, nạp lên GPU, vẽ đè lên video. Ví dụ 50 lá ngẫu nhiên rơi
theo một phương trình quỹ đạo; lá nào rơi hết khỏi khung thì sinh lá mới ngẫu nhiên. Có làm
thuần bằng shader được không?

**Trả lời: được, và engine hiện tại (api 1) đã đủ để chạy bản đầu, không phải sửa Rust.**

- Mỗi lá là **hàm thuần của `(seed, i, t)`**, không cần lưu trạng thái giữa các frame. "Lá
  rơi hết thì sinh lá mới" chính là chuyển sang *thế hệ* tiếp theo của cùng một ô (slot):
  `gen = floor((t + phase_i) / period_i)`, còn tham số ngẫu nhiên của lá là `hash(seed, i, gen)`.
- Kết quả xác định: cùng `t` thì cùng ảnh, seek hay chạy song song đều đúng, và bản thân
  `t` lấy từ pts.
- Đã thử bằng một gói mẫu (atlas PNG 2×2 lá, 1 pass WGSL, 50 lá) với `gpufx check/run`
  trên llvmpipe: shader biên dịch được, chạy hai lần cùng `t` cho ra cùng byte, khác `t` thì
  khác ảnh, và ngay từ `t=0` lá đã rải đều khắp khung.
- Bản api 1 phải tự xử lý trong shader 3 việc: cắt ô atlas, lọc alpha premultiplied bằng tay
  (4 lần `textureLoad`), và chấp nhận răng cưa khi lá vẽ nhỏ hơn nhiều so với ảnh (chưa có
  mipmap). Mục 6 đề xuất `texture_2d_array`, `mipmaps`, `premultiply` để bỏ ba việc này.

## 2. Những gì đã có

| Thành phần | Hiện trạng | Liên quan sprite |
|------------|-----------|------------------|
| `manifest.textures` | `[{name, path}]`, PNG → `Rgba8Unorm`, 1 mip, 1 layer | Nạp được ảnh lá |
| Binding | `@binding(4..)`: `var <name>: texture_2d<f32>` theo `pass.inputs` (mặc định mọi input rồi mọi texture) | Shader thấy texture theo **tên** trong manifest |
| Sampler `smp` | Linear, ClampToEdge, `mipmap_filter` mặc định (Nearest) | Dùng chung cho video và sprite |
| `globals` | `size` (px), `time` (giây, f32, từ pts), `frame` (đếm riêng mỗi filter) | `size` cho tỉ lệ khung, `time` cho chuyển động |
| Tham số | `float/int/bool/vec2/vec3/vec4/color`, biểu thức FFmpeg theo `t` | Đủ cho count, seed, speed... |
| Gói | ≤ 1024 file, ≤ 256 MiB giải nén | Ảnh lá chỉ vài trăm KB |
| Pass | 1 output `rgba8unorm` cùng kích thước input đầu, workgroup 8×8 | Không có buffer lưu trạng thái |

Ràng buộc WGSL quan trọng: `textureSample` chỉ có ở fragment shader (cần đạo hàm ngầm), compute
phải dùng `textureSampleLevel(..., lod)` hoặc `textureLoad`. Hai hàm này gọi được trong luồng
điều khiển không đồng nhất (trong vòng lặp, sau `if`), nên chọn lá hay layer theo từng pixel
không có vấn đề gì.

## 3. Stateless hay stateful

| | Stateless (đề xuất) | Stateful (buffer giữ giữa các frame) |
|--|--------------------|--------------------------------------|
| Trạng thái | `pos = f(seed, i, t)` | Mô phỏng `x += v*dt` mỗi frame trong storage buffer |
| Seek, cắt đoạn, preview kéo thanh thời gian | Đúng ngay | Sai: trạng thái phụ thuộc mọi frame trước. Muốn đúng thì phải mô phỏng lại từ 0 |
| FFmpeg bỏ hoặc lặp frame (framesync, `-r`), filter dựng lại | Không ảnh hưởng | Lệch, hoặc reset về đầu |
| Encode song song theo đoạn | Ghép đoạn khớp nhau | Không khớp ở chỗ nối |
| Thay đổi engine | Không | Cần `buffers` trong manifest, binding storage read_write, `globals.dt`, quy tắc reset khi `t` đi lùi, giữ buffer trong `Effect`, đổi C ABI nếu muốn reset từ FFmpeg |
| Làm được | Quỹ đạo giải tích: rơi, lắc, gió đều, xoay, lật | Thêm va chạm, lá đọng trên vật thể trong video, gió đổi theo thời gian, hàng chục nghìn hạt |

Kết luận: chọn stateless. Stateful để ngoài phạm vi kế hoạch này; khi cần hiệu ứng vật lý
thật thì mở kế hoạch riêng.

Hạn chế của stateless, cần ghi vào tài liệu:
- Tham số làm thay đổi chu kỳ (`speed`, `wind`, `size`, `count`) **không nên** gắn biểu thức
  theo `t`, vì vị trí là `f(t·speed)` chứ không phải tích phân của speed, nên mọi lá sẽ nhảy.
  `opacity` và `seed` (đổi đột ngột) thì gắn biểu thức được.
- Vị trí tính bằng `sin`/`cos` float nên giữa các GPU khác nhau lệch dưới 1 pixel. Trên cùng
  một máy thì kết quả giống nhau từng byte.
- `globals.frame` là bộ đếm riêng của từng filter, không bền khi seek, nên **không dùng**.
  Chỉ dùng `globals.time`. `-ss` trước `-i` (không có `-copyts`) đặt pts về 0 nên lá bắt đầu
  lại từ đầu. Muốn khớp thời gian gốc thì dùng `-copyts` hoặc tham số `offset`.

## 4. Mô hình chuyển động (slot + thế hệ)

Đơn vị toạ độ là chiều cao khung: `x ∈ [0, aspect]`, `y ∈ [0, 1]`, với `aspect = size.x / size.y`.
Lá có kích thước `s` cũng tính theo chiều cao khung, nên giữ nguyên tỉ lệ ở mọi độ phân giải.

Với mỗi slot `i < count`:
1. `margin = 0.75 * size_max` (nửa đường chéo của sprite vuông, cộng thêm phần dư), và
   `dist = 1 + 2*margin` (từ trên mép cho đến khi khuất hẳn dưới đáy).
2. **Chu kỳ cố định cho mỗi slot** `period = dist / (speed * (1 - jitter))`, tức là đủ dài cho
   thế hệ chậm nhất. Chu kỳ phải cố định theo slot để `gen` là hàm thuần của `t`. Nếu tốc độ
   đổi theo thế hệ mà chu kỳ đổi theo thì không tính ngược được `gen`.
3. `local = t + rnd(i, ∞, 0) * period`: pha lệch cho mỗi slot giúp lá đã rải đều từ `t=0`,
   không đổ cùng lúc từ mép trên.
4. `gen = floor(local / period)`. Mỗi thế hệ chọn ngẫu nhiên `dur ≤ period` (tốc độ riêng) và
   độ trễ `delay ∈ [0, period - dur]`, rồi tính `tau = local - gen*period - delay`. Lá chỉ hiện
   khi `0 ≤ tau ≤ dur`, nên khi đổi thế hệ lá luôn ở ngoài khung và không bị giật.
5. Quỹ đạo, viết là hàm riêng nên dễ thay phương trình:
   - `y = -margin + dist * tau / dur`
   - `x = x0 + wind*tau + sway * sin(2π·f·tau/2 + φ)`, với `x0` ngẫu nhiên đã bù trôi do gió
   - góc `θ = φ + spin*k*tau + 0.6*sin(f*tau + φ)` (đung đưa), và scale ngang
     `max(|cos(2f·tau + φ)|, 0.2)` (lá lật)
   - `depth = (i + r) / count`, rồi `s = mix(size_min, size_max, depth)`. **Thứ tự slot chính là
     thứ tự độ sâu**: slot sau to hơn, gần hơn và vẽ đè lên, nên không phải sắp xếp.
   - `layer = floor(r * số_ảnh)`.

## 5. Vẽ trong compute shader

Mỗi pixel đọc màu video rồi duyệt `n` lá và ghép theo phép "over" premultiplied:
1. **Chia việc trong workgroup**: 64 thread của workgroup 8×8 cùng tính `make_leaf` cho
   `n ≤ 256` lá (mỗi thread `i = li, li+64, ...`) và ghi vào `var<workgroup> leaves: array<Leaf, 256>`
   (khoảng 40 B × 256 = 10 KiB, dưới giới hạn mặc định 16 KiB), rồi `workgroupBarrier()`. Nhờ vậy
   hash và lượng giác chỉ chạy khoảng 4 lần mỗi thread thay vì 50 lần mỗi pixel.
   **Barrier phải nằm trong luồng điều khiển đồng nhất**, nên `gpufx_in_bounds` phải gọi *sau* barrier.
2. Mỗi pixel, với từng lá: loại sớm bằng vòng tròn bao (`|p - pos|² > 0.5 s²`). Còn lại thì biến
   đổi ngược pixel vào không gian sprite `q = R(-θ)(p - pos) / scale`, bỏ qua nếu `|q| > 0.5`,
   lấy mẫu tại `uv = q + 0.5`, rồi ghép `acc = c + acc * (1 - c.a)`.
3. Cuối cùng chia lại `acc.rgb / acc.a` để ra alpha thường (straight), vì quy ước output của gpufx
   là straight alpha.

**Chi phí.** Đo bằng `gpufx run` ở 1080p trên llvmpipe 4 nhân (CPU, đã gồm upload/readback):
chỉ copy là 61 ms, 50 lá là 120 ms, 256 lá là 400 ms. Trên GPU thật, mỗi pixel tốn khoảng 50 phép
thử vòng tròn đọc từ shared memory, cộng 1 đến 3 lần lấy mẫu sprite, tức khoảng 0,5 đến 1 Gop
mỗi frame 1080p: dưới 0,5 ms trên GPU rời, khoảng 1 đến 2 ms trên iGPU. Phần này nhỏ so với
upload/readback hiện tại. Chưa cần chia tile cho tới vài trăm lá.
Nếu cần hàng nghìn lá: (a) mỗi workgroup lọc danh sách lá giao với tile 8×8 của mình vào shared
memory (`atomicAdd`); (b) hoặc thêm pass ghi buffer hạt. Cách (b) cần output khác kích thước hay
format (đã có trong lộ trình M1), nên chưa làm bây giờ.

## 6. Nhiều ảnh sprite: chọn `texture_2d_array`

| Cách | Ưu | Nhược |
|------|----|-------|
| Mỗi lá một texture | Có ngay ở api 1 | Phải `switch` theo chỉ số, giới hạn 16 texture mỗi stage (trừ input), mỗi lá thêm một binding |
| Atlas 1 PNG, shader tự cắt ô | Có ngay ở api 1 (bản thử dùng cách này) | Tự tính ô, bị lem màu ô bên cạnh khi lọc tuyến tính và khi có mipmap (phải chừa viền) |
| **`texture_2d_array`** | Chọn bằng `layer`, không lem, mip của từng layer độc lập, `textureNumLayers` | Các layer phải cùng kích thước, cần sửa engine |

**Đề xuất:** thêm texture dạng mảng, nhận ảnh theo 2 cách và cùng ra một `texture_2d_array`:

```json
"api": 2,
"textures": [
  { "name": "leaves",
    "layers": ["textures/maple.png", "textures/oak.png", "textures/birch.png"],
    "mipmaps": true, "premultiply": true },
  { "name": "petals", "path": "textures/petals_atlas.png", "grid": [4, 2], "count": 7,
    "mipmaps": true, "premultiply": true }
]
```

| Trường | Mặc định | Ý nghĩa |
|--------|----------|---------|
| `path` | | 1 PNG. Không có `grid` thì là `texture_2d<f32>` như hiện nay |
| `layers` | | Danh sách PNG **cùng kích thước**, tạo `texture_2d_array<f32>` |
| `grid` | | `[cols, rows]` đi với `path`: cắt atlas thành layer. Chiều rộng/cao phải chia hết |
| `count` | `cols*rows` | Số ô dùng khi ô cuối của lưới bỏ trống |
| `mipmaps` | `false` | Sinh đủ chuỗi mip trên CPU khi nạp |
| `premultiply` | `false` | Nhân RGB với A khi nạp; shader nhận màu premultiplied |

Quy tắc kiểm tra: chỉ được có một trong `path`/`layers`; `grid` chỉ đi với `path`; số layer từ 1
đến 256 (giới hạn mặc định `max_texture_array_layers`); mỗi cạnh ≤ 4096 (thấp hơn
`max_texture_dimension_2d` 8192 để an toàn); tổng texel giải mã của gói ≤ 64 M (256 MiB RGBA8).
Gói dùng trường mới phải khai `"api": 2`, để runtime cũ báo "unsupported manifest api 2" thay
vì lỗi `unknown field` khó hiểu (manifest đang `deny_unknown_fields`). `MANIFEST_API` tăng lên 2,
gói api 1 chạy như cũ.

Shader nhận:

```wgsl
@group(0) @binding(5) var leaves: texture_2d_array<f32>;   // WGSL
layout(set = 0, binding = 5) uniform texture2DArray leaves; // GLSL
// textureSampleLevel(leaves, smp, uv, layer, lod) / textureLod(sampler2DArray(leaves, smp), vec3(uv, layer), lod)
```

**Mipmap.** Compute không có đạo hàm nên shader tự chọn LOD. Với sprite thì tính được chính xác:
`lod = log2(texel_cạnh_sprite / pixel_cạnh_trên_màn)`, tính một lần cho mỗi lá trong `make_leaf`.
Mip sinh trên CPU bằng `image::imageops::resize` (Triangle) trên dữ liệu đã premultiply, rồi
`write_texture` từng (mip, layer); không cần pipeline blit. Sampler chung đặt thêm
`mipmap_filter: Linear`. Texture chỉ có 1 mip thì không bị ảnh hưởng, nên kết quả hiện tại giữ
nguyên. Không có mip thì lá 512 px vẽ ở cỡ 60 px sẽ nhấp nháy. Cách tạm ở api 1 là đóng gói ảnh
lá gần với cỡ hiển thị (128 px).

**Alpha.** PNG là straight alpha. Lọc tuyến tính trên straight alpha làm viền tối hoặc sai màu
(pixel trong suốt thường có RGB = 0), nên `premultiply: true` là lựa chọn đúng cho sprite. Không
bật mặc định để giữ nguyên ý nghĩa của texture hiện có (LUT, mask).

**sRGB/linear.** Giữ `Rgba8Unorm` (không phải `...Srgb`): giá trị PNG được coi như đã cùng
transfer với video (sRGB/BT.709 gamma), ghép trong không gian gamma như phần còn lại của engine.
Khi pipeline chuyển sang linear/HDR (P1) thì xem mục 10.

## 7. Phác thảo shader (api 2)

`make_leaf` giống bản api 1 đã chạy thử, chỉ khác phần chọn `layer` và `lod`.

```wgsl
// Stateless falling leaves: every leaf is a pure function of (seed, slot, time).
const MAX_LEAVES: u32 = 256u;     // = max of the `count` param
const JITTER: f32 = 0.3;          // per-generation speed in [1-j, 1+j] * speed
const TAU: f32 = 6.2831853;

struct Leaf { pos: vec2f, rot: vec2f, scale: vec2f, lod: f32, layer: u32, alive: u32 };
var<workgroup> leaves_wg: array<Leaf, MAX_LEAVES>;

fn hash_u(v: vec4u) -> u32 {
    var x = v.x * 1664525u + v.y * 22695477u + v.z * 2654435761u + v.w * 340573321u + 1013904223u;
    x = x ^ (x >> 16u); x = x * 2246822519u;
    x = x ^ (x >> 13u); x = x * 3266489917u;
    return x ^ (x >> 16u);
}
fn rnd(slot: u32, gen: u32, k: u32) -> f32 {          // k-th random in [0,1) of (slot, gen)
    return f32(hash_u(vec4u(u32(params.seed), slot, gen, k)) >> 8u) / 16777216.0;
}

fn make_leaf(i: u32, t: f32, aspect: f32) -> Leaf {
    var l: Leaf;
    l.alive = 0u;
    let margin = params.size.y * 0.75;
    let dist = 1.0 + 2.0 * margin;
    let period = dist / (params.speed * (1.0 - JITTER));        // fixed per slot
    let local = t + rnd(i, 0xffffffffu, 0u) * period;          // phase: pre-warmed at t = 0
    let gen = u32(floor(local / period));                       // "respawn" = next generation
    let dur = dist / (params.speed * mix(1.0 - JITTER, 1.0 + JITTER, rnd(i, gen, 1u)));
    let tau = local - f32(gen) * period - rnd(i, gen, 2u) * (period - dur);
    if (tau < 0.0 || tau > dur) { return l; }                   // off screen this instant

    let depth = (f32(i) + rnd(i, gen, 3u)) / f32(max(params.count, 1));  // slot order = depth
    let s = mix(params.size.x, params.size.y, depth);
    let ph = rnd(i, gen, 4u) * TAU;
    let f = mix(0.6, 1.4, rnd(i, gen, 5u));
    let x0 = rnd(i, gen, 6u) * (aspect + 2.0 * margin) - margin - params.wind * dur * 0.5;
    // Trajectory: replace these two lines to change the equation of motion.
    l.pos = vec2f(x0 + params.wind * tau + params.sway * sin(f * TAU * 0.5 * tau + ph),
                  -margin + dist * tau / dur);
    let ang = ph + params.spin * tau * (rnd(i, gen, 7u) * 2.0 - 1.0) + 0.6 * sin(f * tau + ph);
    l.rot = vec2f(cos(ang), sin(ang));
    l.scale = vec2f(s * max(abs(cos(2.0 * f * tau + ph)), 0.2), s);    // flip around the stem
    let n = textureNumLayers(leaves);
    l.layer = min(u32(rnd(i, gen, 8u) * f32(n)), n - 1u);
    let texels = f32(textureDimensions(leaves).y);
    l.lod = clamp(log2(texels / (s * globals.size.y)), 0.0, f32(textureNumLevels(leaves) - 1u));
    l.alive = 1u;
    return l;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u, @builtin(local_invocation_index) li: u32) {
    let aspect = globals.size.x / globals.size.y;
    let t = globals.time + params.offset;
    let n = min(u32(max(params.count, 0)), MAX_LEAVES);
    for (var i = li; i < n; i += 64u) { leaves_wg[i] = make_leaf(i, t, aspect); }
    workgroupBarrier();                          // uniform control flow: bounds check after it
    if (!gpufx_in_bounds(id)) { return; }

    let base = textureLoad(src, vec2i(id.xy), 0);
    var acc = vec4f(base.rgb * base.a, base.a);  // premultiplied accumulator
    let p = (vec2f(id.xy) + 0.5) / globals.size.y;
    for (var i = 0u; i < n; i++) {
        let l = leaves_wg[i];
        if (l.alive == 0u) { continue; }
        let d = p - l.pos;
        if (dot(d, d) > 0.5 * l.scale.y * l.scale.y) { continue; }
        let q = vec2f(l.rot.x * d.x + l.rot.y * d.y, l.rot.x * d.y - l.rot.y * d.x) / l.scale;
        if (any(abs(q) > vec2f(0.5))) { continue; }
        let c = textureSampleLevel(leaves, smp, q + 0.5, l.layer, l.lod) * params.opacity; // premultiplied
        acc = c + acc * (1.0 - c.a);
    }
    gpufx_write(id, vec4f(select(vec3f(0.0), acc.rgb / acc.a, acc.a > 0.0), acc.a));
}
```

Bản api 1 (đã chạy thử) thay `textureSampleLevel` bằng hàm tự lọc trên atlas:

```wgsl
const GRID: vec2u = vec2u(2u, 2u);
fn sample_cell(cell: u32, uv: vec2f) -> vec4f {   // premultiplied bilinear, clamped to the cell
    let cell_px = vec2f(textureDimensions(atlas)) / vec2f(GRID);
    let origin = vec2f(f32(cell % GRID.x), f32(cell / GRID.x)) * cell_px;
    let p = origin + uv * cell_px - 0.5;
    let lo = vec2i(floor(p)); let fr = p - floor(p);
    let mn = vec2i(origin); let mx = vec2i(origin + cell_px) - 1;
    var acc = vec4f(0.0);
    for (var k = 0; k < 4; k++) {
        let o = vec2i(k & 1, k >> 1);
        let c = textureLoad(atlas, clamp(lo + o, mn, mx), 0);
        let w = select(1.0 - fr.x, fr.x, o.x == 1) * select(1.0 - fr.y, fr.y, o.y == 1);
        acc += vec4f(c.rgb * c.a, c.a) * w;
    }
    return acc;
}
```

## 8. Gói mẫu `examples/effects/falling-leaves`

```
falling-leaves/
├── manifest.json
├── shaders/leaves.wgsl
└── textures/leaf_{maple,oak,birch,ginkgo}.png   # 128–256 px, nền trong suốt, cùng kích thước
                                                 # (bản api 1: một atlas leaves.png 2×2)
```

| Tham số | Kiểu | Mặc định | Khoảng | Ý nghĩa |
|---------|------|----------|--------|---------|
| `count` | int | 50 | 0–256 | Số slot lá |
| `seed` | int | 1 | | Đổi bộ ngẫu nhiên |
| `speed` | float | 0.18 | 0.01–5 | Chiều cao khung mỗi giây |
| `sway` | float | 0.05 | 0–1 | Biên độ lắc ngang (theo chiều cao khung) |
| `wind` | float | 0.03 | −2–2 | Trôi ngang mỗi giây |
| `size` | vec2 | 0.05, 0.12 | 0.005–1 | Kích thước nhỏ nhất/lớn nhất (theo chiều cao khung) |
| `spin` | float | 1.0 | 0–20 | Tốc độ xoay tối đa (rad/s) |
| `opacity` | float | 1.0 | 0–1 | Độ đậm |
| `offset` | float | 0 | | Cộng vào `t` (khớp thời gian gốc sau `-ss`, đổi thời điểm bắt đầu) |

```sh
ffmpeg -i in.mp4 -vf "gpufx=effect=falling-leaves.zip:params='count=80|wind=-0.05|opacity=clip(t\,0\,1)'" out.mp4
```

## 9. Các chỗ còn thiếu (gap) trong engine

| # | Gap | Ảnh hưởng | Xử lý |
|---|-----|-----------|-------|
| G1 | Không có `texture_2d_array` | Phải dùng atlas và tự cắt ô, hoặc `switch` qua nhiều texture | Bước 2 |
| G2 | Không có mipmap, sampler `mipmap_filter` Nearest | Lá nhỏ bị răng cưa, nhấp nháy | Bước 3 |
| G3 | Texture luôn straight alpha | Viền tối khi lọc, phải lọc 4 tap bằng tay | Bước 3 (`premultiply`) |
| G4 | Không kiểm kích thước PNG khi nạp: vượt `max_texture_dimension_2d` thì lỗi wgpu đi vào uncaptured error handler (mặc định panic, làm sập process FFmpeg); PNG nhỏ có thể giải mã ra ảnh rất lớn | An toàn với gói không tin cậy | Bước 2: kiểm cạnh ≤ 4096, ngân sách texel của gói, đặt `image::Limits` |
| G5 | `create_texture`/`upload` chỉ có 1 layer, 1 mip; bind layout luôn `D2`; view tạo mặc định (array 1 layer sẽ ra view `D2`) | | Bước 2: lưu loại texture theo từng binding, tạo view với `dimension` rõ ràng |
| G6 | Tài liệu chưa nói về `var<workgroup>` + `workgroupBarrier` (phải ở luồng điều khiển đồng nhất, kiểm `gpufx_in_bounds` sau barrier) và giới hạn 16 KiB shared memory | Tác giả dễ viết shader sai | Bước 4 |
| G7 | `globals.frame` không bền khi seek; tham số biểu thức đổi chu kỳ làm lá nhảy | Tác giả dùng nhầm | Bước 4 (tài liệu) |
| G8 | Output pass chỉ `rgba8unorm`, cùng kích thước khung | Không lưu bảng hạt ra buffer được, giới hạn khoảng 256 lá cho mỗi pass | Để sau (M1 "output size khác input"); không cần cho 50 lá |
| G9 | Chưa có hàm hash/rand dùng chung | Mỗi gói chép lại hàm hash | Để sau (M1 `#include` thư viện shader) |

Không phải gap: tỉ lệ khung (`globals.size`), kích thước texture (`textureDimensions`), param
`int`/`vec2`, giới hạn gói 256 MiB / 1024 file.

## 10. Liên quan tới A2 (chuỗi hiệu ứng) và YUV trên GPU

- **A2, nhiều effect trong một lần upload/readback:** sprite là một pass 1 input bình thường
  và stateless, nên nối chuỗi không đổi gì về logic. Khi gộp nhiều gói vào một graph GPU, tên
  texture của từng gói phải có namespace riêng. Texture array và mip thuộc `Program` của từng
  gói, dùng chung giữa các `Effect` như hiện nay. Loại binding (`D2`/`D2Array`) lấy theo từng
  pass, không giả định chung. `var<workgroup>` gói gọn trong từng pass.
- **YUV trên GPU, `rgba16float` (P1/B-chung):** shader ghi qua `gpufx_write`, nên đổi format
  `out_tex` không ảnh hưởng. Sprite vẫn là `rgba8unorm` (chỉ đọc). Nếu pipeline chuyển sang
  linear-light/HDR thì PNG sRGB phải được đổi transfer: dành sẵn trường
  `"colorspace": "srgb" | "linear"` cho texture (mặc định `srgb`) và quy định ngay bây giờ rằng
  giá trị texture "cùng transfer với video". Premultiply nên làm sau khi linear hoá, nên bước
  3 phải đặt premultiply ở một chỗ duy nhất trong code nạp texture để sau này đổi thứ tự dễ.
- **Zero-copy (P3+):** không ảnh hưởng, vì texture gói nạp một lần lúc tạo `Program`.

## 11. Các bước

| Bước | Nội dung | Ước lượng |
|------|----------|-----------|
| 1 | Gói mẫu `falling-leaves` **trên api 1** (atlas 2×2, `sample_cell`, workgroup cache), 4 ảnh lá tự vẽ hoặc giấy phép CC0. Thêm vào bảng ví dụ trong `EFFECT_FORMAT.md`. Không sửa Rust | ~130 dòng WGSL + manifest + PNG (<100 KB) |
| 2 | Manifest: `layers`, `grid`, `count`, `api 2`, kiểm tra quy tắc và giới hạn (G4). Runtime: tạo texture array, `write_texture` từng layer, `TextureKind` cho mỗi binding, prelude WGSL/GLSL (`texture_2d_array`/`texture2DArray`), view có `dimension` | ~200–250 dòng Rust + test manifest |
| 3 | `mipmaps` (sinh mip trên CPU, `mipmap_filter: Linear`), `premultiply` | ~100–150 dòng Rust |
| 4 | Chuyển `falling-leaves` lên api 2 (`layers`, mip, premultiplied, LOD tự tính), bỏ `sample_cell`. Tài liệu: mục "Sprite và hạt" trong `EFFECT_FORMAT.md` (mẫu stateless, barrier, LOD, alpha, cảnh báo biểu thức), cập nhật lộ trình trong `DESIGN.md` | ~60 dòng WGSL thay đổi, ~80 dòng tài liệu |
| 5 | Test (mục 12) và chạy `scripts/test-bundle.sh` | ~120 dòng |
| Sau | Stateful buffers; pass ghi buffer hạt; lọc theo tile; thư viện `#include` có `gpufx_hash`; `colorspace` | Kế hoạch riêng |

Bước 1 dùng được ngay và độc lập. Bước 2 và 3 có thể gộp thành một PR engine.

## 12. Test

Rust (`crates/gpufx-core/tests/effects.rs`, bỏ qua khi không có GPU, chạy được trên lavapipe):
- `falling_leaves_is_stateless`: một `Effect` xử lý các frame `t = 0, 1/30, ..., 3` theo thứ tự,
  một `Effect` mới chỉ xử lý `t = 3`; kết quả ở `t = 3` phải giống nhau từng byte. Xử lý ngược
  thứ tự cũng phải ra cùng kết quả.
- Cùng `t` thì giống nhau; `t = 0.5` và `t = 1.0` thì khác nhau; khác `seed` thì khác nhau.
- `count = 0` hoặc `opacity = 0` thì output bằng input. Lá chỉ được đè, không làm đổi pixel
  ngoài lá.
- Mật độ ổn định: với `t ∈ {0, 7.3, 61.7, 3600}`, tỉ lệ pixel bị lá che nằm trong một khoảng
  (ví dụ 2–30%). Ca này bắt lỗi "đổ hết cùng lúc" và lỗi "lá không sinh lại".
- `every_example_compiles_and_runs` tự chạy gói mới.

Engine (bước 2–3):
- Manifest: báo lỗi khi `path` và `layers` cùng có, layer khác kích thước, `grid` không chia
  hết, `count > cols*rows`, quá 256 layer, cạnh > 4096, dùng trường mới với `api: 1`.
- Runtime: gói 2 layer (PNG đỏ và PNG xanh), shader chọn layer theo `uv.x`, kiểm màu; `grid`
  2×1 cho cùng kết quả như `layers`; ô bàn cờ 2×2 có `mipmaps` lấy ở LOD cao nhất ra xám;
  `premultiply` đổi `(255,0,0,0)` thành `(0,0,0,0)`. Gói api 1 cũ cho output không đổi.

Bundle (`scripts/test-bundle.sh`): vòng lặp hiệu ứng 1 input tự chạy `falling-leaves.zip`. Thêm
một ca so md5: frame tại `t=2` lấy từ lần chạy đầy đủ (`select`) phải bằng frame lấy bằng
`-ss 2 -copyts` (chứng minh seek-safe qua FFmpeg thật).
