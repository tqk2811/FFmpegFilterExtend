English: [EFFECT_FORMAT.md](EFFECT_FORMAT.md)

# Định dạng gói hiệu ứng và cách viết shader (api 2)

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
gpufx run 'my-effect=strength=0.8' -i in.png -o out.png
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
| `api` | số | không (1) | Phiên bản định dạng. Cần `2` cho texture mảng, `mipmaps`, `premultiply` và tham số `expr`; gói không dùng các trường này giữ `1` và chạy như cũ. Runtime cũ hơn gói sẽ báo `unsupported manifest api 2` |
| `id` | chuỗi | có | Định danh dạng reverse-DNS |
| `name` | chuỗi | có | Tên hiển thị |
| `version`, `description` | chuỗi | không | |
| `inputs` | mảng | không (`[{"name":"src"}]`) | Các video input, theo thứ tự pad của filter, kèm quy tắc (xem bên dưới) |
| `output` | `{formats}` | không (`rgba` và mọi format chuyển trên GPU) | Pixel format output được phép |
| `params` | mảng | không | Tham số, xem bên dưới |
| `textures` | mảng | không | Ảnh PNG đi kèm (LUT, mask, sprite), xem [Texture](#texture) |
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
| `mipmaps` | `false` | (api 2) Texture của input có đủ chuỗi mip, sinh trên GPU mỗi frame, cho shader thu nhỏ ảnh nhiều (`textureSampleLevel(src, smp, uv, lod)`); xem [Mipmap](#mipmap) |

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
| `type` | `float`, `int`, `bool`, `vec2`, `vec3`, `vec4`, `color`, `expr` (api 2) |
| `default` | Số, mảng số, `true/false`, hoặc chuỗi (`"#ff8800"`; biểu thức của `expr`) |
| `min`, `max` | Giá trị bị kẹp vào khoảng này (không dùng cho `expr`) |
| `vars` | Chỉ cho `expr`: tên các biến của biểu thức, theo thứ tự tham số của hàm trong shader |
| `description` | Mô tả |

Kiểu trong shader: `float`→`f32`/`float`, `int`→`i32`/`int`, `bool`→`u32`/`uint` (0 hoặc 1),
`vecN`→`vecNf`/`vecN`, `color`→`vec4f`/`vec4` (RGBA 0..1). `expr` không nằm trong `params` mà trở
thành một hàm, xem [Tham số biểu thức](#tham-số-biểu-thức).

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
Param không được tên `enable` hay `bypass`: các key inline `enable=` và `bypass=` của một effect (`effect='my-effect.zip=enable=lt(t\,2)'`) dùng để bật/tắt một effect của chain hoặc graph.

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
// Texture có `layers` hoặc `grid` là texture_2d_array<f32> (GLSL: texture2DArray).
// Mỗi tham số `expr` thêm fn gpufx_expr_<name>(<vars>: f32...) -> f32.
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

## Texture

Mỗi phần tử `textures` tạo một texture `rgba8unorm` chỉ đọc từ các file PNG trong gói, gắn theo `name`
(không trùng input, output của pass hay texture khác):

```json
"api": 2,
"textures": [
  { "name": "lut", "path": "textures/lut.png" },
  { "name": "leaves", "layers": ["textures/maple.png", "textures/oak.png"], "mipmaps": true, "premultiply": true },
  { "name": "petals", "path": "textures/petals.png", "grid": [4, 2], "count": 7, "mipmaps": true, "premultiply": true }
]
```

| Trường | Mặc định | Ý nghĩa |
|--------|----------|---------|
| `name` | | Tên trong shader |
| `path` | | Một PNG. Không có `grid` thì là `texture_2d<f32>` (api 1) |
| `layers` | | (api 2) Các PNG **cùng kích thước**, là các layer của `texture_2d_array<f32>`, theo thứ tự |
| `grid` | | (api 2) `[cols, rows]` đi với `path`: cắt atlas thành các layer của `texture_2d_array<f32>`, theo từng hàng. Rộng và cao phải chia hết |
| `count` | `cols*rows` | (api 2) Số ô dùng, khi các ô cuối bỏ trống |
| `mipmaps` | `false` | (api 2) Sinh đủ chuỗi mip trên CPU khi nạp gói (mỗi mức từ mức trên, lọc tam giác, sau `premultiply`) |
| `premultiply` | `false` | (api 2) Nhân RGB với alpha khi nạp: shader đọc màu premultiplied |

Quy tắc: có đúng một trong `path`/`layers`; `grid` chỉ đi với `path`, `count` chỉ đi với `grid`; từ 1 đến
256 layer; mỗi ảnh tối đa **4096** pixel mỗi cạnh (runtime cũng kiểm `max_texture_dimension_2d` và
`max_texture_array_layers` của device và báo lỗi, thay vì để wgpu làm sập process); tổng ảnh của gói
giải mã ra tối đa **64 M texel** (256 MiB RGBA8). Kích thước lấy từ header PNG khi mở gói (`gpufx check`
báo luôn), và bộ giải mã bị giới hạn, nên file nhỏ khai ảnh rất lớn bị từ chối trước khi tốn bộ nhớ.

Việc nạp làm một lần cho mỗi gói và device, trên CPU: ảnh đã giải mã, các layer đã cắt và chuỗi mip (thêm
một phần ba) cùng nằm trong RAM tới khi upload, nên đỉnh khoảng gấp đôi kích thước giải mã (tới khoảng
700 MiB với gói chạm giới hạn 64 M texel). PNG 16 bit được giải mã ở 16 bit (gấp đôi số byte, tính vào
giới hạn 256 MiB mỗi ảnh của bộ giải mã) rồi giảm về 8 bit: texture của gói luôn là `rgba8unorm`. Các mức
mip được lọc trên alpha premultiplied kể cả khi tắt `premultiply` (rồi chia lại), nên pixel trong suốt
không làm tối viền.

Texture mảng đọc theo chỉ số layer, chỉ số này có thể khác nhau theo từng pixel:

```wgsl
let n = textureNumLayers(leaves);                              // số layer
let c = textureSampleLevel(leaves, smp, uv, layer, lod);       // layer: u32 hoặc i32
let d = textureLoad(leaves, vec2i(x, y), layer, 0);
```
```glsl
vec4 c = textureLod(sampler2DArray(leaves, smp), vec3(uv, layer), lod);
```

Mỗi layer bị kẹp ở mép của chính nó: khác với atlas tự cắt, lọc tuyến tính và mip không bao giờ lem
sang ảnh bên cạnh.

**Alpha.** Màu PNG là straight alpha, pixel trong suốt thường có RGB = 0: lọc (bilinear, mip) làm tối
viền sprite. Với `premultiply: true` texture giữ màu premultiplied và lọc đúng; ghép bằng
`acc = c + acc * (1 - c.a)` rồi chia lại cho alpha trước `gpufx_write` (nhận straight alpha). Mặc định tắt
để LUT và mask giữ nguyên giá trị.

**Màu.** Giá trị texture được coi là cùng transfer với video (sRGB/BT.709 gamma), không chuyển đổi, như
phần còn lại của engine. Khi pipeline chuyển sang linear, sẽ có trường `colorspace` quy định cách đổi.

### Mipmap

Sampler chung `smp` lọc tuyến tính giữa các mức mip (`mipmap_filter: Linear`); texture chỉ có 1 mức lấy
mẫu y như trước. Compute shader không có đạo hàm nên shader tự chọn mức:
`lod = log2(số texel theo chiều ngang / số pixel trên màn)`, ví dụ tính một lần cho mỗi sprite thay vì
mỗi pixel. Không có mip thì ảnh vẽ nhỏ hơn nhiều so với kích thước thật sẽ nhấp nháy, răng cưa.

Input cũng có mip được (`"mipmaps": true` trong `inputs`): chuỗi mip được sinh trên GPU ngay sau khi
chuyển đổi input, hoặc sau hiệu ứng ghi ra nó trong chuỗi/đồ thị, mỗi frame, ngay trong texture của
frame (tốn thêm một phần ba bộ nhớ của texture đó, không copy). Hiệu ứng đọc cùng frame mà không khai
`mipmaps` chỉ thấy mức 0. Mỗi mức là trung bình 2×2 có trọng số alpha. Dùng khi hiệu ứng thu nhỏ ảnh
nhiều (ảnh 4000 px trong một hộp nhỏ).

## Sprite và hạt

`falling-maple`/`falling-ginkgo` vẽ tới 256 sprite trong một pass compute. Mẫu chung:

- **Không trạng thái:** mỗi hạt là hàm thuần của `(seed, slot, thời gian)`. Mỗi slot lặp một chu kỳ cố
  định; chu kỳ mới là một hạt ngẫu nhiên mới ("sinh lại"), đổi khi hạt ở ngoài khung. Nhờ vậy seek, bỏ
  hoặc lặp frame và encode chia đoạn đều cho cùng ảnh. Dùng `globals.time_int` và `time_frac` (hoặc
  `time`), **không dùng `globals.frame`**: nó đếm riêng mỗi filter và về 0 khi seek. `-ss` trước `-i`
  (không có `-copyts`) đặt thời gian về 0; tham số `offset` giúp bù lại.
- **Cache trong workgroup:** 64 thread của workgroup tính các hạt một lần vào
  `var<workgroup> leaves: array<Leaf, 256>` (ở đây 40 byte mỗi hạt: giữ dưới giới hạn mặc định 16 KiB),
  rồi `workgroupBarrier()`. Barrier phải nằm trong **luồng điều khiển đồng nhất**: gọi
  `gpufx_in_bounds` *sau* barrier, không phải trước.
- **Mỗi pixel:** bỏ qua hạt có vòng tròn bao không chứa pixel, đổi pixel sang không gian sprite, lấy mẫu
  texture mảng ở mức mip tính cho từng sprite, ghép premultiplied.
- **Tham số quyết định chu kỳ** (`speed`, `wind`, `size`, `count`, `life`) không nên là biểu thức
  FFmpeg theo `t`: vị trí là `f(t * speed)` chứ không phải tích phân của speed, nên mọi hạt sẽ nhảy.
  `opacity` và `seed` thì theo `t` được.
- Vị trí tính bằng `sin`/`cos` f32 lệch dưới một pixel giữa các GPU; trên cùng một máy output giống nhau
  từng byte.

## Tham số biểu thức

Tham số `expr` (api 2) giữ một biểu thức toán, truyền dạng chuỗi như mọi tham số (inline sau tên package trong `effect=`/`graph=` của filter,
`sendcmd`, inline trong `gpufx run`), và được tính trên GPU ở chỗ shader gọi nó, ví dụ mỗi hạt một lần:

```json
{ "name": "path_x", "type": "expr", "vars": ["u", "p", "x0"], "default": "x0 + 0.05*sin(tau*u)" }
```

```wgsl
let x = gpufx_expr_path_x(u, p, x0);   // tham số theo thứ tự `vars`, đều là f32
```

- Chuỗi chỉ được có số (`1`, `0.5`, `2e-3`), các biến đã khai, hằng `pi`, `tau`, `e`, `+ - * /`, `^`
  (lũy thừa), ngoặc và các hàm `sin cos tan asin acos atan atan2 abs sign min max clamp mix step
  smoothstep pow sqrt exp log floor ceil round fract`. Không gì khác: chuỗi được parse thành cây và code
  shader sinh từ cây, không chèn chuỗi thô. Tối đa 1024 byte, 512 số hạng, lồng 32 mức.
- Hàm trả về `f32`. NaN và vô cực (`log(-1)`, `1/0`) được đổi thành **0**, nên shader không bao giờ thấy
  chúng (hạt ở vị trí 0 vẫn có thể nằm trong khung: nên chọn công thức luôn xác định).
- Tên biến là định danh thường: bắt đầu bằng chữ cái, không có `__`.
- Biểu thức mới làm biên dịch lại pipeline của hiệu ứng (vài ms): thỉnh thoảng đổi (`sendcmd`), không
  đổi mỗi frame. Biểu thức được biên dịch ngay lúc đặt, nên chuỗi parse hay biên dịch lỗi báo lỗi tại đó
  (`sendcmd` báo lại) và giữ biểu thức đúng gần nhất; stream vẫn chạy tiếp. Biểu thức mặc định dùng
  pipeline chung của mọi hiệu ứng mở từ gói.
- Trên dòng lệnh FFmpeg, dấu phẩy trong `effect='...'`/`graph='...'` phải escape như mọi option của filter, còn
  các key inline phân tách bằng `&` (không cần escape): `effect='x.zip=angle=max(90*u\,0)&speed=2'`. Dấu `:` kiểu
  FFmpeg cũng được chấp nhận nhưng ở đó phải viết `\:` (`...\,0)\:speed=2`). Trong chuỗi effect, `\&` là `&`
  nguyên văn (tập ký tự escape được: `\ ' : & ; | = [ ]`).

## Ví dụ có sẵn

Các ví dụ nằm trong ba thư mục nhóm dưới `examples/effects/`: `ffmpeg/` (tương đương filter dựng sẵn và chuyển cảnh `xfade` của FFmpeg), `slideshow/` (viết lại từ [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts)) và `standalone/` (hiệu ứng tự viết). Xem [examples/effects/README.md](../examples/effects/README.md). Nhóm chỉ là thư mục: gói vẫn được gọi bằng tên riêng của nó.

| Gói | Minh hoạ |
|-----|----------|
| `examples/effects/ffmpeg/vignette` | Tham số `float` + `color` |
| `examples/effects/ffmpeg/gaussian-blur` | 2 pass qua texture trung gian `tmp` |
| `examples/effects/ffmpeg/wipe-transition` | 2 input (`first`, `second`), tham số `progress` |
| `examples/effects/standalone/gradient-map` | Texture PNG đi kèm làm LUT |
| `examples/effects/standalone/rgb-split` | GLSL, dùng `globals.frame` làm nhiễu động |
| `examples/effects/ffmpeg/color-adjust` | Độ sáng, tương phản, bão hoà, gamma, hue, nhiệt độ màu |
| `examples/effects/ffmpeg/grayscale`, `examples/effects/ffmpeg/sepia`, `examples/effects/ffmpeg/invert` | Lọc màu cơ bản, tham số `amount` |
| `examples/effects/ffmpeg/sharpen` | Unsharp mask 3×3 bằng `textureLoad` |
| `examples/effects/ffmpeg/edge-detect` | Sobel |
| `examples/effects/ffmpeg/pixelate` | Khảm theo khối |
| `examples/effects/ffmpeg/mirror` | Lật ngang/dọc, tham số `int` |
| `examples/effects/ffmpeg/transform` | Zoom, xoay, pan (Ken Burns), tham số `vec2` |
| `examples/effects/ffmpeg/fade` | Fade về một màu |
| `examples/effects/ffmpeg/chroma-key` | Phông xanh → alpha; **quy tắc** `formats` input, output `rgba`/`yuva420p`/`yuva444p` |
| `examples/effects/ffmpeg/overlay` | Picture-in-picture 2 input, có viền |
| `examples/effects/ffmpeg/crossfade`, `examples/effects/ffmpeg/slide-transition`, `examples/effects/ffmpeg/circle-reveal` | Chuyển cảnh 2 input; **quy tắc** `same_size` |
| `examples/effects/ffmpeg/clock-wipe` | Chuyển cảnh kim đồng hồ, tham số `bool` `reverse` |
| `examples/effects/slideshow/collapse`, `examples/effects/slideshow/expand` | Clip đầu thu vào giữa / clip sau nở ra từ giữa: theo chiều ngang, chiều dọc, hộp, hình tròn (`mode`) |
| `examples/effects/ffmpeg/dip-to-color` | Tối dần về một màu (mặc định đen) rồi hiện clip sau |
| `examples/effects/ffmpeg/dissolve` | Hạt ngẫu nhiên (hash số nguyên, giống nhau trên mọi GPU) |
| `examples/effects/ffmpeg/pixelize-transition`, `examples/effects/ffmpeg/zoom-transition`, `examples/effects/ffmpeg/fade-grays`, `examples/effects/slideshow/blinds` | Chuyển cảnh kiểu `xfade`: vỡ điểm ảnh, zoom, qua ảnh xám, rèm |
| `examples/effects/slideshow/checkerboard`, `examples/effects/slideshow/push-box`, `examples/effects/slideshow/push-film`, `examples/effects/slideshow/photo-collection` | Chuyển cảnh slideshow theo [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts) (viết lại bằng shader): ô vuông lớn dần, hộp thu nhỏ - đẩy - phóng to, cuộn phim có lỗ vẽ bằng shader, ảnh bay vào vừa xoay vừa đáp nghiêng lên clip đầu (nối chuỗi để xếp chồng ảnh) |
| `examples/effects/slideshow/box-in`, `examples/effects/slideshow/sliding-bars`, `examples/effects/slideshow/spin-transition` | Cũng theo các script đó: clip đầu thu nhỏ thành hộp rồi trượt ra, hộp clip sau trượt vào từ cùng phía rồi phóng to (`box_in_*`), các thanh của clip sau lần lượt trượt vào (`stagger`), clip đầu xoay thu nhỏ rồi clip sau xoay phóng to có motion blur (vòng lặp nhiều mẫu theo góc). `slide-transition` có thêm `mode` đẩy / phủ / lộ / đẩy qua khoảng trống màu `color`, `blinds` có `origin` mở từ giữa thanh |
| `examples/effects/slideshow/fit` | Các chế độ khung hình của các script đó (giữa, cắt, kéo giãn, nền mờ) cho ảnh kích thước bất kỳ: input đầu chỉ cho kích thước khung; **hai pass**, box blur tách trục với số tap bilinear cố định |
| `examples/effects/standalone/falling-maple`, `examples/effects/standalone/falling-ginkgo` | Lá phong đỏ / lá rẻ quạt vàng rơi: (api 2): atlas 2×2 cắt thành **texture mảng** (`grid`) có **mipmap** và **alpha premultiplied**, mức mip tính cho từng lá, hạt không trạng thái (chỉ phụ thuộc `t`, seek đúng), `var<workgroup>` + `workgroupBarrier`, 4 kiểu chuyển động (`mode`) và quỹ đạo tùy chỉnh (`mode=4`, **tham số `expr`** `path_x`, `path_y`, `angle`). Ảnh gốc và giấy phép ở `assets/leaves/` |
