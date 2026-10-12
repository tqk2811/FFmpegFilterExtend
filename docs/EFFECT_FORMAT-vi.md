English: [EFFECT_FORMAT.md](EFFECT_FORMAT.md)

# Định dạng gói hiệu ứng và cách viết shader (api 1)

## Cấu trúc gói

Một gói là file `.zip` (hoặc một thư mục khi phát triển) có `manifest.json` ở gốc. Đường dẫn
trong manifest tính từ gốc gói, dùng `/`.

```
my-effect/
├── manifest.json
├── shaders/main.wgsl
└── textures/lut.png
```

Đóng gói và kiểm tra:

```sh
gpufx check my-effect            # biên dịch mọi shader, báo lỗi kèm vị trí
gpufx run my-effect -i in.png -o out.png -p strength=0.8
gpufx pack my-effect my-effect.zip
```

Đóng gói nhiều hiệu ứng một lúc (không cần build FFmpeg hay Docker):

```sh
scripts/pack-effects.sh                         # mọi thư mục trong examples/effects -> dist/effects/*.zip
scripts/pack-effects.sh --check -o out my-fx    # biên dịch shader trên GPU trước, ghi vào out/
.\scripts\pack-effects.ps1 -Check                # Windows
```

## manifest.json

| Trường | Kiểu | Bắt buộc | Ý nghĩa |
|--------|------|----------|---------|
| `api` | số | không (1) | Phiên bản định dạng |
| `id` | chuỗi | có | Định danh dạng reverse-DNS |
| `name` | chuỗi | có | Tên hiển thị |
| `version`, `description` | chuỗi | không | |
| `inputs` | mảng | không (`[{"name":"src"}]`) | Các video input, theo thứ tự pad của filter, kèm quy tắc (xem bên dưới) |
| `output` | `{formats}` | không (`rgba` và mọi format chuyển trên GPU) | Pixel format output được phép |
| `params` | mảng | không | Tham số, xem bên dưới |
| `textures` | mảng `{name, path}` | không | Ảnh PNG đi kèm (LUT, mask) |
| `passes` | mảng | có | Các pass compute, chạy theo thứ tự |

## Quy tắc input/output

Gói có thể khai báo input nhận format/kích thước nào và output ra format nào. Stream
không khớp sẽ **bị báo lỗi** (filter không tự chuyển đổi ngầm), lỗi nêu rõ input và quy tắc:

```
unsupported: input `src` of `Chroma Key`: pixel format `gray` is not supported (accepted: yuv420p, rgba)
unsupported: input `second` of `Crossfade`: size 300x180 must equal the first input (320x180)
```

Mỗi phần tử `inputs`:

| Trường | Mặc định | Ý nghĩa |
|--------|----------|---------|
| `name` | | Tên input, cũng là tên texture trong shader |
| `description` | | Mô tả |
| `formats` | `[]` (mọi format) | Pixel format nhận (tên của FFmpeg: `yuv420p`, `nv12`, `rgba`, `rgb24`...) |
| `width`, `height` | không giới hạn | `{ "min": 16, "max": 4096, "multiple_of": 2 }`, mỗi trường đều tuỳ chọn |
| `same_size` | `false` | Kích thước phải bằng input đầu tiên (không dùng cho input đầu) |

`output.formats`: danh sách pixel format output được phép, theo thứ tự ưu tiên. Không có `output` thì
danh sách là `rgba`, `rgba64le`, `nv12`, `p010le`, `yuv420p`, `yuv422p`, `yuv444p`, `yuv420p10le`,
`yuv422p10le`, `yuv444p10le`, `yuva420p`, `yuva444p`: các format gpufx ghi trên GPU. Vì vậy hiệu ứng
không có `output.formats` có thể xuất YUV không alpha: alpha mà hiệu ứng ghi bị bỏ, trừ khi filter
phía sau nhận format có alpha. **Hiệu ứng tạo ra alpha nên khai báo `output.formats`** (ví dụ
`["rgba", "yuva420p"]`). FFmpeg
chọn một format trong danh sách khi nối filter; filter phía sau đòi format ngoài danh sách
thì FFmpeg tự chèn bộ chuyển đổi sau `gpufx`.

```json
"inputs": [
  { "name": "src", "formats": ["yuv420p", "nv12", "rgba"],
    "width": { "min": 64, "multiple_of": 2 }, "height": { "min": 64, "multiple_of": 2 } },
  { "name": "matte", "formats": ["gray"], "same_size": true }
],
"output": { "formats": ["yuva420p", "rgba"] }
```

Cách áp dụng:

- **FFmpeg:** input không có `formats` nhận các format gpufx chuyển trên GPU (danh sách trên, thêm
  `yuvj420p`/`yuvj422p`/`yuvj444p`); FFmpeg đổi format khác sang một trong số đó. Input có
  `formats` nhận nguyên format của stream; khác danh sách thì lỗi khi cấu hình filter graph.
  Muốn chạy thì đổi format trước bằng `format=yuv420p,gpufx=...`. Kích thước được kiểm tra
  khi cấu hình và mỗi khi kích thước frame đổi. Tên format sai chính tả cũng là lỗi.
- **Chuỗi và đồ thị** (`effect='a|b'`, `graph='...'`): mỗi hiệu ứng được kiểm tại chỗ của nó. Hiệu ứng
  đọc hiệu ứng khác thấy kích thước của hiệu ứng đó (kích thước input đầu của nó) và format đầu tiên
  trong `output.formats` của nó mà hiệu ứng đọc nhận; input pad được nhiều hiệu ứng đọc phải có
  format mà tất cả đều nhận. Vì vậy `same_size` cũng áp dụng giữa hai nhánh của đồ thị.
- **`gpufx run`:** format lấy từ PNG (`rgba`, `rgb24`, `gray`, `ya8`, bản 16-bit là
  `rgba64be`, `rgb48be`, `gray16be`, `ya16be`). CLI luôn ghi PNG RGBA nên không kiểm tra
  `output.formats`.
- Shader luôn thấy RGBA alpha thường (straight), dù format vào/ra là gì: chuyển đổi chạy trên GPU,
  ngoài shader. Texture là `rgba8unorm`, hoặc `rgba16float` khi input hay output của chuỗi trên 8 bit
  (video 10-bit giữ được độ chính xác).

Mỗi phần tử `params`:

| Trường | Ý nghĩa |
|--------|---------|
| `name` | Tên, cũng là tên trường trong `params.<name>` |
| `type` | `float`, `int`, `bool`, `vec2`, `vec3`, `vec4`, `color` |
| `default` | Số, mảng số, `true/false`, hoặc chuỗi (`"#ff8800"`) |
| `min`, `max` | Giá trị bị kẹp vào khoảng này |
| `description` | Mô tả |

Kiểu trong shader: `float`→`f32`/`float`, `int`→`i32`/`int`, `bool`→`u32`/`uint` (0 hoặc 1),
`vecN`→`vecNf`/`vecN`, `color`→`vec4f`/`vec4` (RGBA 0..1).

Mỗi phần tử `passes`:

| Trường | Mặc định | Ý nghĩa |
|--------|----------|---------|
| `shader` | | File shader trong gói |
| `language` | theo đuôi file | `wgsl` hoặc `glsl` (`.glsl`, `.comp` là GLSL) |
| `entry` | `main` | Hàm compute (WGSL; GLSL luôn là `main`) |
| `inputs` | mọi input rồi mọi texture | Texture pass này đọc: tên input, texture, hoặc output của pass trước |
| `output` | `out` | Tên texture pass này ghi. Pass cuối là kết quả |

Output có kích thước bằng input đầu tiên. Tên input/texture/param phải là định danh hợp lệ,
không trùng nhau, không bắt đầu bằng `gpufx` và không dùng `globals`, `params`, `out_tex`, `smp`.

## Viết shader WGSL

Runtime chèn sẵn phần khai báo sau (ví dụ cho gói có input `src` và tham số `strength`):

```wgsl
struct GpufxGlobals {
    size: vec2f,          // kích thước output (px)
    time: f32,            // thời gian (giây); f32 mất độ chính xác khi clip dài
    frame: u32,           // số frame, đếm riêng mỗi filter (không bền khi seek)
    time_int: i32,        // thời gian chính xác: time_int + time_frac giây,
    time_frac: f32,       //   time_frac trong [0, 1), kể cả khi thời gian âm
    pixel_aspect: f32,    // rộng / cao của một pixel (SAR), 1 với pixel vuông
    gpufx_reserved: f32,
};
struct GpufxParams { strength: f32 };
@group(0) @binding(0) var<uniform> globals: GpufxGlobals;
@group(0) @binding(1) var<uniform> params: GpufxParams;
@group(0) @binding(2) var out_tex: texture_storage_2d<rgba8unorm, write>; // rgba16float khi trên 8 bit
@group(0) @binding(3) var smp: sampler;
@group(0) @binding(4) var src: texture_2d<f32>;
fn gpufx_in_bounds(id: vec3u) -> bool
fn gpufx_uv(id: vec3u) -> vec2f          // tâm pixel, 0..1
fn gpufx_write(id: vec3u, c: vec4f)      // kẹp 0..1 rồi ghi
```

Chuyển động theo thời gian nên dựa vào `time_int` và `time_frac` nếu clip có thể dài: `time`
là f32 nên sau một ngày chỉ còn bước khoảng 0,008 s. Xem `falling-*/shaders/leaves.wgsl`, đếm
thời gian theo tick số nguyên.

Shader của bạn chỉ cần:

```wgsl
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    gpufx_write(id, vec4f(c.rgb * params.strength, c.a));
}
```

Lưu ý:
- Runtime dispatch theo nhóm **8×8**; hãy dùng `@workgroup_size(8, 8)`.
- Trong compute shader không có đạo hàm, nên dùng `textureSampleLevel(..., 0.0)` hoặc
  `textureLoad` thay cho `textureSample`.
- Màu là RGBA 0..1 (8-bit hoặc half float), không chuyển đổi gamma (giá trị sRGB như trong video).
  Luôn ghi qua `gpufx_write`: storage format của `out_tex` tuỳ theo frame (trong GLSL prelude khai báo
  `rgba8` hoặc `rgba16f`).

## Viết shader GLSL

GLSL 450 compute theo kiểu Vulkan (texture và sampler tách rời). Nếu file có `#version` thì
prelude được chèn ngay sau dòng đó, nếu không runtime tự thêm `#version 450`.

```glsl
#version 450
layout(local_size_x = 8, local_size_y = 8) in;

void main() {
    uvec3 id = gl_GlobalInvocationID;
    if (!gpufx_in_bounds(id)) return;
    vec4 c = textureLod(sampler2D(src, smp), gpufx_uv(id), 0.0);
    gpufx_write(id, vec4(c.rgb * params.strength, c.a));
}
```

## Ví dụ có sẵn

| Gói | Minh hoạ |
|-----|----------|
| `examples/effects/vignette` | Tham số `float` + `color` |
| `examples/effects/gaussian-blur` | 2 pass qua texture trung gian `tmp` |
| `examples/effects/wipe-transition` | 2 input (`first`, `second`), tham số `progress` |
| `examples/effects/gradient-map` | Texture PNG đi kèm làm LUT |
| `examples/effects/rgb-split` | GLSL, dùng `globals.frame` làm nhiễu động |
| `examples/effects/color-adjust` | Độ sáng, tương phản, bão hoà, gamma, hue, nhiệt độ màu |
| `examples/effects/grayscale`, `sepia`, `invert` | Lọc màu cơ bản, tham số `amount` |
| `examples/effects/sharpen` | Unsharp mask 3×3 bằng `textureLoad` |
| `examples/effects/edge-detect` | Sobel |
| `examples/effects/pixelate` | Khảm theo khối |
| `examples/effects/mirror` | Lật ngang/dọc, tham số `int` |
| `examples/effects/transform` | Zoom, xoay, pan (Ken Burns), tham số `vec2` |
| `examples/effects/fade` | Fade về một màu |
| `examples/effects/chroma-key` | Phông xanh → alpha; **quy tắc** `formats` input, output `rgba`/`yuva420p`/`yuva444p` |
| `examples/effects/overlay` | Picture-in-picture 2 input, có viền |
| `examples/effects/crossfade`, `slide-transition`, `circle-reveal` | Chuyển cảnh 2 input; **quy tắc** `same_size` |
| `examples/effects/clock-wipe` | Chuyển cảnh kim đồng hồ, tham số `bool` `reverse` |
| `examples/effects/collapse`, `expand` | Clip đầu thu vào giữa / clip sau nở ra từ giữa: theo chiều ngang, chiều dọc, hộp, hình tròn (`mode`) |
| `examples/effects/dip-to-color` | Tối dần về một màu (mặc định đen) rồi hiện clip sau |
| `examples/effects/dissolve` | Hạt ngẫu nhiên (hash số nguyên, giống nhau trên mọi GPU) |
| `examples/effects/pixelize-transition`, `zoom-transition`, `fade-grays`, `blinds` | Chuyển cảnh kiểu `xfade`: vỡ điểm ảnh, zoom, qua ảnh xám, rèm |
| `examples/effects/checkerboard`, `push-box`, `push-film`, `photo-collection` | Chuyển cảnh slideshow theo [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts) (viết lại bằng shader): ô vuông lớn dần, hộp thu nhỏ - đẩy - phóng to, cuộn phim có lỗ vẽ bằng shader, ảnh bay vào vừa xoay vừa đáp nghiêng lên clip đầu (nối chuỗi để xếp chồng ảnh) |
| `examples/effects/fit` | Các chế độ khung hình của các script đó (giữa, cắt, kéo giãn, nền mờ) cho ảnh kích thước bất kỳ: input đầu chỉ cho kích thước khung; **hai pass**, box blur tách trục với số tap bilinear cố định |
| `examples/effects/falling-maple`, `falling-ginkgo` | Lá phong đỏ / lá rẻ quạt vàng rơi: **ảnh PNG trong gói** (atlas 2×2), hạt không trạng thái (chỉ phụ thuộc `t`, seek đúng), `var<workgroup>` + `workgroupBarrier`, 4 kiểu chuyển động (`mode`). Ảnh gốc và giấy phép ở `assets/leaves/` |
