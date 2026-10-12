English: [DESIGN.md](DESIGN.md)

# Thiết kế: FFmpegFilterExtend (gpufx)

> Mục tiêu: chạy hiệu ứng video bằng **shader trên GPU** trong `filter_graph` của FFmpeg,
> với hiệu ứng được **nạp từ gói `.zip` bên ngoài** (kiểu CapCut). Thêm hiệu ứng mới không
> cần build lại FFmpeg: chỉ cần đưa gói zip, tham số, và nối input/output trong graph.

## 1. Yêu cầu

| # | Yêu cầu | Cách đáp ứng |
|---|---------|--------------|
| R1 | **Shader là ưu tiên số 1** (lý do dùng GPU) | Mỗi hiệu ứng *là* một chuỗi compute shader. Hỗ trợ WGSL và GLSL ngay từ bản đầu, kiểm tra lỗi shader có số dòng, nhiều pass, texture đi kèm, tham số tự sinh thành `uniform` |
| R2 | Đa hệ điều hành | Windows, Linux, macOS (Android/iOS về sau) |
| R3 | Đa phần cứng / API | Vulkan, DirectX 12, Metal, OpenGL qua **wgpu**; CUDA/D3D11/VAAPI qua interop (giai đoạn 2) |
| R4 | Hiệu ứng nạp ngoài, không build lại FFmpeg | Một filter duy nhất `gpufx` build **một lần**; hiệu ứng là gói zip |
| R5 | Dùng Rust hoặc C/C++ | Engine viết bằng **Rust**; phần nối vào FFmpeg là một file C nhỏ |

## 2. Tổng quan kiến trúc

```
 ffmpeg -vf "gpufx=effect=vignette.zip:params='strength=0.8'"
            │
            ▼
 ┌────────────────────────────┐   C ABI (gpufx.h)    ┌──────────────────────────────────┐
 │ libavfilter/vf_gpufx.c     │ ───────────────────▶ │ libgpufx (Rust, crates/gpufx-ffi) │
 │  - option effect/params    │                      │  gpufx-core:                      │
 │  - pad input động theo     │                      │   package  : đọc zip / thư mục    │
 │    manifest (1..N input)   │                      │   manifest : schema, kiểm tra     │
 │  - framesync nhiều input   │                      │   params   : layout uniform       │
 │  - biểu thức theo t, n     │                      │   runtime  : biên dịch shader,    │
 │  - sendcmd / timeline      │                      │              chạy pass trên wgpu  │
 └────────────────────────────┘                      └───────────────┬──────────────────┘
                                                                     │ wgpu
                                         ┌────────────┬──────────────┼─────────────┬────────┐
                                         ▼            ▼              ▼             ▼        ▼
                                      Vulkan      DirectX 12       Metal        OpenGL   (WebGPU)
```

**Vì sao chỉ một filter?** FFmpeg không có cơ chế plugin filter lúc chạy: mọi filter phải
được biên dịch vào `libavfilter`. Vì vậy ta thêm *một* filter chung `gpufx` (patch một lần,
xem `ffmpeg/integrate.sh`), còn toàn bộ logic hiệu ứng nằm trong shader của gói zip. Đây
chính là mô hình CapCut: app cố định, hiệu ứng là dữ liệu tải về.

**Vì sao Rust + wgpu?**
- wgpu là lớp trừu tượng GPU đã chín, chạy Vulkan/DX12/Metal/GL từ cùng một mã nguồn.
- Đi kèm **naga**: trình biên dịch shader thuần Rust, đọc WGSL, GLSL, SPIR-V và dịch sang
  SPIR-V/HLSL/MSL/GLSL cho từng backend. Đây là phần quan trọng nhất cho R1: tác giả viết
  shader **một lần**, chạy trên mọi API.
- Rust an toàn bộ nhớ khi đọc gói zip không tin cậy; xuất C ABI ổn định cho FFmpeg.

Phương án đã cân nhắc và loại:

| Phương án | Lý do không chọn làm lõi |
|-----------|---------------------------|
| Vulkan + SPIR-V trực tiếp (như `libplacebo`) | Không chạy native trên macOS/DX; phải tự viết lại phần wgpu đã có |
| Viết riêng CUDA/DX/Vulkan cho từng hiệu ứng | Trái R4: mỗi hiệu ứng × mỗi API |
| OpenCL (`vf_program_opencl`) | Driver kém đồng đều, không có trên macOS mới, không phải shader đồ hoạ |
| Gắn vào `libplacebo` custom shader | Chỉ Vulkan, cú pháp mpv hook, không hỗ trợ nhiều input |

## 3. Gói hiệu ứng (`.zip`)

```
vignette.zip
├── manifest.json        bắt buộc
├── shaders/*.wgsl|*.comp|*.glsl
└── textures/*.png       tuỳ chọn (LUT, mask, overlay)
```

Chi tiết định dạng và cách viết shader: [EFFECT_FORMAT-vi.md](EFFECT_FORMAT-vi.md).

Tóm tắt `manifest.json`:

```json
{
  "api": 1,
  "id": "io.github.tqk2811.gaussian-blur",
  "name": "Gaussian Blur",
  "inputs": [{ "name": "src" }],
  "params": [{ "name": "radius", "type": "float", "default": 6, "min": 0, "max": 48 }],
  "passes": [
    { "shader": "shaders/blur_h.wgsl", "inputs": ["src"], "output": "tmp" },
    { "shader": "shaders/blur_v.wgsl", "inputs": ["tmp"], "output": "out" }
  ]
}
```

- `inputs` quyết định số pad input của filter (transition dùng 2 input, v.v.).
- `params` được runtime **tự sinh** thành struct `params` trong shader, đúng quy tắc căn lề
  uniform của WGSL/std140; tác giả chỉ việc dùng `params.radius`.
- `passes` chạy tuần tự; output của pass trước là texture đọc được ở pass sau; pass cuối là
  đầu ra.

## 4. Mô hình shader (trọng tâm)

Mỗi pass là một **compute shader**. Trước mã của tác giả, runtime chèn một *prelude* sinh tự
động (giống cách Shadertoy cung cấp `iResolution`, `iTime`):

| Binding | Tên trong shader | Ý nghĩa |
|---------|------------------|---------|
| 0 | `globals.size`, `globals.time`, `globals.frame`, `globals.time_int`, `globals.time_frac`, `globals.pixel_aspect` | Kích thước output (px), thời gian (giây, f32), số frame, thời gian chính xác (giây nguyên + phần lẻ), tỉ lệ cạnh của pixel (SAR) |
| 1 | `params.<tên>` | Tham số từ manifest |
| 2 | `out_tex` | Texture ghi kết quả (`rgba8unorm`) |
| 3 | `smp` | Sampler tuyến tính, clamp |
| 4.. | tên input/texture/pass | Texture đọc (`texture_2d<f32>`) |

Kèm hàm tiện ích `gpufx_in_bounds(id)`, `gpufx_uv(id)`, `gpufx_write(id, color)`.

Vì sao compute thay vì fragment shader: không cần render pass/vertex buffer, dễ làm nhiều
pass, đọc/ghi tự do (blur tách trục, histogram, reduce) và ánh xạ thẳng sang CUDA/Metal
compute khi cần.

Ngôn ngữ shader:

| Ngôn ngữ | Trạng thái | Ghi chú |
|----------|-----------|---------|
| WGSL | ✅ prototype | Ngôn ngữ chuẩn của WebGPU, lỗi rõ ràng nhất |
| GLSL 450 (compute) | ✅ prototype | Thuận tiện để port shader có sẵn (GL Transitions, Shadertoy) |
| SPIR-V (biên dịch sẵn) | Kế hoạch | Cho tác giả dùng HLSL/Slang → SPIR-V bằng công cụ ngoài |
| HLSL / Slang | Kế hoạch | Biên dịch trong `gpufx pack` sang SPIR-V/WGSL |
| Fragment shader kiểu Shadertoy (`mainImage`) | Kế hoạch | Bọc tự động thành compute |

Kiểm tra shader trước khi chạy: naga phân tích và validate, lỗi trả về kèm tên file và vị
trí trong mã (thử: `gpufx check <gói>`). Filter FFmpeg in lỗi đó qua `av_log` và từ chối khởi
tạo graph thay vì chạy sai.

## 5. Filter FFmpeg `gpufx`

```
gpufx=effect=<zip|thư mục>[|<zip>...][:params='a=1|b=#ff0000|c=clip(t/2\,0\,1)'][:backend=auto|vulkan|dx12|metal|gl][:shortest=0|1]
```

- **effect**: đường dẫn gói. Số input của filter lấy từ manifest.
- **Chuỗi hiệu ứng** `effect='a.zip|b.zip|c.zip'`: chạy lần lượt như ba filter nối nhau, nhưng
  frame chỉ upload một lần, mọi pass nằm trong một lần submit GPU và chỉ readback một lần.
  Input của filter là input của hiệu ứng đầu; chỉ hiệu ứng đầu được có nhiều input. Output
  theo quy tắc của hiệu ứng cuối. Quy tắc của hiệu ứng sau được kiểm như khi nối filter:
  format là format đầu tiên trong `output.formats` của hiệu ứng trước mà hiệu ứng sau nhận,
  kích thước là kích thước input đầu. Frame vẫn là RGBA trên GPU, không chuyển sang format đó.
  Tham số đặt theo `gói.tên` (tên file bỏ `.zip`, ví dụ `vignette.strength`), `chỉ_số.tên`
  (đếm từ 0, bắt buộc khi hai gói trùng tên hoặc tên gói là số), hoặc tên trơn nếu chỉ một
  hiệu ứng có nó. Dấu cách quanh `|` được bỏ qua.
- **params**: `tên=giá trị` cách nhau bởi `|`. Giá trị là literal (`0.5`, `1,0,0`, `#ff8800`)
  hoặc **biểu thức FFmpeg** theo `t`, `n`, `w`, `h`, `a` (`w/h`), `sar`, `dar` (`a*sar`),
  tính lại mỗi frame. Đây là cách làm keyframe/transition không cần tool ngoài.
- **sendcmd / zmq**: lệnh `params` đổi giá trị lúc chạy, ví dụ
  `sendcmd=c='2.0 gpufx@fx params strength=0.2'`.
- **timeline** (`enable='between(t,1,3)'`) được hỗ trợ.
- Nhiều input dùng `framesync`: input đầu quyết định độ dài và frame rate (input khác lệch
  fps thì frame của nó được lặp hoặc bỏ). Input khác chưa bắt đầu thì là ảnh trong suốt; đã
  hết thì giữ frame cuối (hoặc `shortest=1`).
- Output nhận kích thước, SAR, frame rate của input đầu; colorspace/range/alpha là giá trị
  đã negotiate của link output. Side data phụ thuộc màu (HDR metadata, film grain...), motion
  vector và video enc params bị bỏ vì pixel đã khác.
- Kích thước hay pixel format của input đổi giữa chừng thì báo lỗi (`ffmpeg` tự dựng lại
  graph nên chỉ gặp khi dùng libavfilter trực tiếp).
- Cảnh báo (không chặn): SAR các input khác nhau, input trên 8 bit (pipeline 8-bit RGBA),
  input HDR PQ/HLG (shader coi như SDR), input interlaced (shader thấy hai field là một
  frame). Shader làm việc với alpha thường (straight): filter tự bỏ premultiply của input
  (EXR, JPEG XL…) và premultiply lại khi output cần.

Ví dụ:

```sh
# 1 input, tham số động theo thời gian
ffmpeg -i in.mp4 -vf "gpufx=effect=vignette.zip:params='strength=clip(t/2\,0\,1)|color=#200040'" out.mp4

# transition 2 input
ffmpeg -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect=wipe-transition.zip:params='progress=clip((t-1)/1.5\,0\,1)|angle=45'" out.mp4

# xâu chuỗi nhiều hiệu ứng: hai filter, mỗi filter một lần upload/readback
ffmpeg -i in.mp4 -vf "gpufx=effect=gaussian-blur.zip,gpufx=effect=gradient-map.zip:params='intensity=0.6'" out.mp4

# cùng kết quả trong một filter: upload và readback một lần
ffmpeg -i in.mp4 -vf "gpufx=effect='gaussian-blur.zip|gradient-map.zip':params='gradient-map.intensity=0.6'" out.mp4
```

## 6. Đường đi của frame và hiệu năng

**Prototype (đã chạy):** frame RGBA trong RAM → upload texture → các pass compute → copy về
RAM. Input không khai báo `formats` thì FFmpeg tự chèn `scale`/`format` để chuyển YUV ↔ RGBA;
input có `formats` (và output khác RGBA) thì filter nhận nguyên frame, kiểm tra theo quy tắc
của manifest rồi tự chuyển bằng `swscale`. Các filter `gpufx` trong cùng
process dùng chung một GPU device.

Gói đã nạp cũng được dùng chung. Mỗi gói (khoá theo đường dẫn tuyệt đối và GPU device) chỉ
được đọc và biên dịch một lần trong process: `Program` gồm manifest, pipeline, texture PNG,
sampler. Mỗi filter giữ một `Effect` riêng gồm giá trị tham số, uniform buffer và texture
frame. Khi không còn filter nào dùng gói thì `Program` được giải phóng, lần mở sau đọc lại
file. Sửa file zip khi vẫn còn filter dùng gói đó thì không có tác dụng, kể cả với filter
mở gói sau khi sửa.

Chi phí chính là upload/readback và chuyển màu trên CPU. Lộ trình bỏ dần:

| Giai đoạn | Thay đổi | Lợi ích |
|-----------|----------|---------|
| P1 | Chuyển YUV (NV12/P010/yuv420p) ↔ RGBA trên GPU trong runtime; texture `rgba16float` cho pass trung gian | Bỏ `swscale`, hỗ trợ 10-bit/HDR |
| P2 | Pipeline hoá: double buffer readback, không chặn chờ frame trước | Tăng throughput 2–3× trên GPU rời |
| P3 | **Zero-copy** với `AV_PIX_FMT_VULKAN`: tạo wgpu device từ `AVVulkanDeviceContext` (`wgpu-hal` `create_device_from_hal`) và nhập `VkImage` của `AVVKFrame` | Không qua RAM khi decode/encode bằng Vulkan |
| P4 | Interop **CUDA** (NVDEC/NVENC): `hwmap` CUDA → Vulkan (external memory) hoặc `VK_KHR_external_memory` trực tiếp | Dùng được với `-hwaccel cuda` |
| P5 | Interop **D3D11/D3D12** (Windows, QSV/AMF/D3D11VA) bằng shared NT handle sang DX12 của wgpu | Dùng được với `-hwaccel d3d11va` |
| P6 | VAAPI/DRM-PRIME (Linux), VideoToolbox (`CVPixelBuffer` → `MTLTexture`) | Phủ hết hwaccel phổ biến |

Ở mọi giai đoạn, **định dạng gói và shader không đổi**: tác giả không cần biết frame đến từ
CPU hay CUDA.

## 7. Bảo mật gói hiệu ứng

Gói zip là dữ liệu không tin cậy (tải từ chợ hiệu ứng):
- Chặn path traversal (`..`, đường dẫn tuyệt đối), giới hạn số file và tổng dung lượng giải nén.
- Không có mã native trong gói: chỉ shader, được naga validate trước khi đưa xuống driver.
- wgpu kiểm tra truy cập buffer/texture; vòng lặp vô hạn trong shader có thể treo GPU →
  giai đoạn sau: giới hạn thời gian dispatch, ký số gói (`signature` trong manifest).

## 8. Cấu trúc repo

```
crates/gpufx-core   engine Rust: package, manifest, params, runtime (wgpu)
crates/gpufx-ffi    libgpufx (.so/.dll/.dylib + .a) và include/gpufx.h
crates/gpufx-cli    lệnh `gpufx`: info, check, pack, run (test hiệu ứng không cần FFmpeg)
ffmpeg/             vf_gpufx.c và integrate.sh (thêm filter vào cây nguồn FFmpeg)
external/FFmpeg     submodule FFmpeg, ghim n9.0-2-g03d9533176 (release/9.0) = commit của bản build sẵn
docker/, build.sh   build FFmpeg + gpufx một lệnh trong Docker (linux64, win64)
examples/effects    36 hiệu ứng: chỉnh màu, blur, sharpen, chroma key, overlay, chuyển cảnh...
scripts/            build-prebuilt.sh (chỉ build libavfilter, thay vào FFmpeg build sẵn),
                    test-bundle.sh (chạy hiệu ứng qua ffmpeg của gói),
                    install-libgpufx.sh (build + cài .pc cho pkg-config),
                    pack-effects.sh/.ps1 (chỉ đóng gói hiệu ứng thành zip)
```

## 9. Bản build phân phối

**Cách nhanh (CI dùng cách này):** `scripts/build-prebuilt.sh [linux64|win64]` tải bản FFmpeg
9.0 shared build sẵn (tqk2811/FFmpegBuild), build `libgpufx` và **chỉ `libavfilter`** từ
submodule với `--disable-everything` + `docker/keep-filters.txt` + gpufx, rồi thay
`libavfilter.so.12` / `avfilter-12.dll` trong gói. Điều kiện để dùng chung ABI:

- cùng commit FFmpeg với bản build sẵn (submodule ghim `03d9533176`, script kiểm tra);
- cùng tên major (`libavfilter.so.12`, `avfilter-12.dll`); script dừng nếu bản build sẵn
  không có file trùng tên;
- ffmpeg CLI chỉ dùng API công khai và tìm filter theo tên lúc chạy, nên bớt filter không
  làm hỏng việc nạp thư viện. Danh sách giữ lại phải có các filter CLI tự chèn: `null`/`anull`,
  `format`/`aformat`, `scale`/`aresample`, `trim`/`atrim`, `apad`, `crop`, `hflip`, `vflip`,
  `transpose`, `rotate`.
- Linux: RUNPATH của `libavfilter` là `$ORIGIN` (đặt bằng `patchelf`, vì configure của FFmpeg
  biến `$$` thành PID), và mọi file trong `bin/` được sửa RPATH thành `$ORIGIN/../lib`.
  Trước khi thay, script so bảng export (`nm -D`) của `libavfilter` mới với bản build sẵn: thiếu
  symbol nào thì dừng.
- `libavfilter` rút gọn chỉ link `avutil`, `swscale`, `swresample`, nên không build
  `avcodec`/`avformat`/`avdevice`. Có `nasm` thì bật SIMD.
- win64: `avfilter-12.dll` dùng `msvcrt.dll` còn bản build sẵn dùng UCRT (xem
  [Backlog-vi.md](Backlog-vi.md)).
- win64: `bin/` có `dxcompiler.dll` (DXC, tải từ NuGet bằng `scripts/fetch-dxc.sh`, kiểm
  sha256). wgpu tìm nó cạnh `ffmpeg.exe` để biên dịch shader cho D3D12; thiếu nó thì wgpu
  dùng FXC cũ, chậm tới vài phút với shader nhiều vòng lặp (lá rơi). `WGPU_DX12_COMPILER=fxc`
  ép dùng FXC.

`scripts/test-bundle.sh dist/<target>` chạy mọi hiệu ứng, biểu thức, `sendcmd`, timeline và
các ca quy tắc phải báo lỗi qua `ffmpeg` của gói. CI chạy nó cho linux64 (lavapipe) và cho
win64 trên runner `windows-latest`.

**Build đầy đủ:** `./build.sh [linux64|win64|all]` (hoặc `build.ps1` trên Windows) dựng image Docker, build
`libgpufx` bằng Rust, chép submodule `external/FFmpeg` ra thư mục tạm (submodule giữ
nguyên), chạy `integrate.sh`, rồi configure FFmpeg với:

- `--disable-filters` rồi bật lại **mọi filter audio** cùng danh sách tối thiểu trong
  `docker/keep-filters.txt` (`null`, `format`, `scale`, `trim`, `crop`, `hflip`, `vflip`,
  `transpose`, `rotate`, `sendcmd`, `split`, `gpufx`). Các filter video còn giữ là hạ tầng
  mà ffmpeg CLI tự chèn (trim cho `-ss/-t`, xoay theo metadata) hoặc gpufx cần (đổi
  YUV ↔ RGBA). Khi gpufx tự chuyển màu trên GPU (P1), có thể bỏ thêm `scale`.
- `libgpufx` được link động: Linux dùng `rpath=$ORIGIN` để tìm `libgpufx.so` cạnh `ffmpeg`,
  Windows đặt `gpufx.dll` cạnh `ffmpeg.exe`. DLL chỉ phụ thuộc DLL hệ thống
  (đã kiểm tra bằng `objdump`).
- win64 cross-compile bằng mingw-w64 như BtbN/FFmpeg-Builds. macOS chưa có (cần build
  native trên máy Mac).

## 10. Lộ trình

1. **M0 – Prototype (PR này):** gói zip, WGSL + GLSL, nhiều pass, nhiều input, texture,
   tham số + biểu thức, filter FFmpeg 9.0, CLI, 5 hiệu ứng mẫu, test tự động.
2. **M1 – Shader:** SPIR-V/HLSL/Slang, wrapper Shadertoy `mainImage`, `#include` thư viện
   shader chung (màu, noise, blend mode), hot-reload khi phát triển, output size khác input
   (crop/zoom/pad), sampler tuỳ chọn (nearest/repeat/mirror).
3. **M2 – Hiệu năng:** P1–P2 ở mục 6, benchmark trên NVIDIA/AMD/Intel/Apple.
4. **M3 – Zero-copy:** P3–P6.
5. **M4 – Hệ sinh thái:** ký gói, kho hiệu ứng, công cụ preview/chỉnh tham số trực quan,
   công cụ chuyển đổi một số định dạng hiệu ứng phổ biến (GL Transitions, `.cube` LUT).
