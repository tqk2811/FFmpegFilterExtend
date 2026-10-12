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

## manifest.json

| Trường | Kiểu | Bắt buộc | Ý nghĩa |
|--------|------|----------|---------|
| `api` | số | không (1) | Phiên bản định dạng |
| `id` | chuỗi | có | Định danh dạng reverse-DNS |
| `name` | chuỗi | có | Tên hiển thị |
| `version`, `description` | chuỗi | không | |
| `inputs` | mảng `{name, description?}` | không (`[{"name":"src"}]`) | Các video input, theo thứ tự pad của filter |
| `params` | mảng | không | Tham số, xem bên dưới |
| `textures` | mảng `{name, path}` | không | Ảnh PNG đi kèm (LUT, mask) |
| `passes` | mảng | có | Các pass compute, chạy theo thứ tự |

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
struct GpufxGlobals { size: vec2f, time: f32, frame: u32 };
struct GpufxParams { strength: f32 };
@group(0) @binding(0) var<uniform> globals: GpufxGlobals;
@group(0) @binding(1) var<uniform> params: GpufxParams;
@group(0) @binding(2) var out_tex: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(3) var smp: sampler;
@group(0) @binding(4) var src: texture_2d<f32>;
fn gpufx_in_bounds(id: vec3u) -> bool
fn gpufx_uv(id: vec3u) -> vec2f          // tâm pixel, 0..1
fn gpufx_write(id: vec3u, c: vec4f)      // kẹp 0..1 rồi ghi
```

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
- Màu là RGBA 8-bit, 0..1, không chuyển đổi gamma (giá trị sRGB như trong video).

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
