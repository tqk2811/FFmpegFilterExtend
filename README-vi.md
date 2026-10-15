# FFmpegGpuFilter (gpufx)

Hiệu ứng video chạy bằng **shader trên GPU** cho FFmpeg, nạp từ **gói `.zip`** bên ngoài
(kiểu CapCut). FFmpeg chỉ cần build một lần với filter `gpufx`; hiệu ứng mới là gói zip mới.

- Shader **WGSL** hoặc **GLSL**, nhiều pass, nhiều input, texture đi kèm, tham số tự sinh.
- Filter FFmpeg chạy trên frame **Vulkan, Direct3D 12, Direct3D 11** và **Metal** (macOS) (qua
  [wgpu](https://wgpu.rs)), Windows/Linux/macOS. OpenGL chỉ dùng được qua thư viện và CLI `gpufx`, chưa
  có test.
- Tham số là literal hoặc biểu thức theo thời gian; đổi lúc chạy bằng `sendcmd`.
- Nhiều hiệu ứng trong một filter (`effect='blur.zip|vignette.zip'`): cả chuỗi chạy trong một lần
  submit GPU, không qua frame trung gian.
- Cả **đồ thị hiệu ứng** trong một filter (`graph='[0]split[a][b]; [a]blur.zip[x]; [x][b]crossfade.zip[out]'`):
  rẽ nhánh, nhiều input và nhiều output, tất cả trong một lần submit GPU; `split` không chép gì và
  texture trung gian lấy từ pool.
- Gói khai báo **quy tắc input/output** (pixel format, kích thước, cùng kích thước giữa
  các input); stream không khớp thì báo lỗi rõ ràng thay vì chuyển đổi ngầm.
- 36 hiệu ứng mẫu: chỉnh màu, đen trắng, sepia, sharpen, pixelate, chroma key,
  picture-in-picture, đặt ảnh vào khung trên nền mờ, lá phong / lá rẻ quạt rơi (texture mảng có mipmap, quỹ đạo tùy chỉnh bằng biểu thức), chuyển cảnh (crossfade, slide, wipe, circle, clock, collapse, expand,
  dip to black, dissolve, pixelize, zoom, blinds, bàn cờ, đẩy hộp, cuộn phim, xếp ảnh...)

- **Frame Vulkan không copy**: frame của `hwupload` (`AV_PIX_FMT_VULKAN`, mỗi plane một image) được xử lý tại chỗ
  trên chính device Vulkan của FFmpeg, đồng bộ bằng timeline semaphore của nó; giữa các filter frame không quay
  về RAM. Frame của decoder Vulkan (`-hwaccel vulkan`) là image multiplane nên hiện bị từ chối.
- **Frame D3D12 và D3D11** (Windows): frame `AV_PIX_FMT_D3D12` (`-init_hw_device d3d12va`) được xử lý tại chỗ trên
  chính `ID3D12Device` của FFmpeg, đồng bộ bằng fence của frame; frame `AV_PIX_FMT_D3D11` chạy trên device D3D12 cùng
  adapter qua shared NT handle (output không copy, input khác tốn một lần copy GPU). nv12 và p010le.
  Đã chạy trên NVIDIA RTX 4060 Laptop và Intel UHD Graphics (Windows 11); CI chỉ build.
- Cache shader trên đĩa (tuỳ chọn): `GPUFX_SHADER_CACHE=<thư mục>` (pipeline cache của Vulkan; DXIL của D3D12 khi
  tìm thấy `dxcompiler.dll` trên đường tìm DLL). `gpufx pack --precompile` gói sẵn shader D3D12 vào gói, chỉ dùng khi
  `GPUFX_TRUST_PRECOMPILED=1` (xem [thiết kế](docs/DESIGN-vi.md)).

```sh
# gpufx trả ra frame GPU: đưa cho nó một device (frame CPU ở input nó tự upload) và
# download trước encoder
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect=wipe-transition.zip:params='progress=clip((t-1)/1.5\,0\,1)|angle=45',hwdownload,format=yuv420p" out.mp4
```

```sh
# đồ thị hình thoi trên GPU, hai output pad ghi ra hai file
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0:v][1:v]gpufx=graph='[0]split[a][b]; [a]gaussian-blur.zip[ba]; [b]grayscale.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[x]; [x]split[x1][x2]; [x2][1]wipe-transition.zip[w]':params='x.progress=0.5|w.progress=t'[mix][wipe];[mix]hwdownload,format=yuv420p[m];[wipe]hwdownload,format=yuv420p[w2]" \
  -map "[m]" mix.mp4 -map "[w2]" wipe.mp4
```

```sh
# một chuỗi: gpufx đầu tiên upload, mọi hiệu ứng chạy trên device Vulkan của FFmpeg, download một lần
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx=effect=vignette.zip,gpufx=effect=sepia.zip,hwdownload,format=nv12" out.mp4
# D3D12 (Windows): như trên với -init_hw_device d3d12va=dx -filter_hw_device dx
```

```sh
# Truyền nhanh hơn (Vulkan): gpufx_upload/gpufx_download chạy copy nối đuôi; out_format=rgba giữ
# các gpufx rời ở RGBA giữa chúng (filter cuối quay về nv12)
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx=effect=vignette.zip:out_format=rgba,gpufx=effect=sepia.zip:out_format=nv12,gpufx_download,format=nv12" out.mp4
```

Giống các filter `*_cuda` của FFmpeg, `gpufx` **chỉ trả ra frame GPU** (Vulkan, D3D12, D3D11, hoặc VideoToolbox trên macOS). Input có thể là
frame GPU (`hwupload`, `gpufx_upload`, một `gpufx` khác) hoặc frame CPU; frame CPU được `gpufx` tự upload lên device
của các input GPU, hoặc lên `-filter_hw_device` khi không input nào nằm trên GPU; không có device thì filter dừng và
báo cần thêm option nào. Trước filter CPU và encoder phải có `hwdownload,format=<fmt>` hoặc
`gpufx_download,format=<fmt>` (`<fmt>` là format của output, mặc định là format của input nếu hiệu ứng được phép trả
ra format đó). Vì vậy một chuỗi `gpufx` chỉ upload mỗi frame một lần và readback một lần. Từ nhanh tới chậm:

1. một `gpufx=graph=...` chứa mọi hiệu ứng;
2. các filter riêng kẹp giữa `gpufx_upload` và `gpufx_download`, `out_format=rgba` trên mọi filter trừ cái cuối;
3. các filter riêng sau một lần upload (do `gpufx` đầu tiên hoặc `hwupload`), rồi `hwdownload`.

GPU Intel trên Windows với FFmpeg 9: `hwupload` (và `hwdownload` frame của `hwupload`) báo lỗi cấp phát hoặc
làm hỏng ảnh do host image copy của driver; dùng `gpufx_upload` / `gpufx_download`, hoặc mở device với
`disable_multiplane=1,linear_images=1`. `gpufx` từ chối các frame đó. Xem [docs/INTEL_VULKAN-vi.md](docs/INTEL_VULKAN-vi.md).

Option `backend` của filter chỉ để thử nghiệm (để mặc định `auto`, tự theo frame); filter từ chối `backend=gl`, và cả
`backend=metal` trừ trên macOS (thư viện và CLI `gpufx` vẫn nhận). Trên macOS
filter chạy trên frame VideoToolbox (nv12, p010le) qua Metal, ví dụ
`-init_hw_device videotoolbox=vt -filter_hw_device vt -vf "gpufx=effect=vignette.zip,hwdownload,format=nv12"`;
đường này chưa chạy trên máy Mac nào (xem bên dưới).

Tài liệu: [thiết kế](docs/DESIGN-vi.md) · [định dạng gói và cách viết shader](docs/EFFECT_FORMAT-vi.md) · [đo tốc độ](docs/BENCHMARK-vi.md) · [English](README.md)

## Yêu cầu phần cứng và hệ điều hành

- **Windows**: Windows 10 64-bit trở lên. D3D12: feature level 11_0, resource binding tier 2 (NVIDIA Kepler+,
  AMD GCN+, Intel Skylake+). Frame D3D11: Windows 10 1703+ (shared fence D3D11.4).
- **Linux**: Vulkan 1.1+ có queue graphics + compute và timeline semaphore (FFmpeg 9 xin 1.3);
  NVIDIA proprietary, Mesa RADV/ANV, lavapipe (CPU). Bundle linux64 cần glibc 2.35+ (Ubuntu 22.04).
- **macOS**: Metal; frame VideoToolbox cần Apple silicon (nv12/p010le). Chưa chạy trên Mac.
- GPU Intel trên Windows với frame Vulkan của FFmpeg 9: xem [Intel Vulkan](docs/INTEL_VULKAN-vi.md).

Chi tiết, nguồn và lỗi đã biết: [docs/REQUIREMENTS-vi.md](docs/REQUIREMENTS-vi.md).

## Build

Cần Rust (stable) và một driver GPU (Linux không có GPU có thể dùng `mesa-vulkan-drivers`/lavapipe).

```sh
cargo build --release
cargo test --release                       # chạy các hiệu ứng mẫu trên GPU hiện có
./target/release/gpufx run examples/effects/vignette -i in.png -o out.png -p strength=0.9
scripts/pack-effects.sh                    # chỉ đóng gói hiệu ứng: examples/effects -> dist/effects/*.zip
```

Thêm hoặc sửa hiệu ứng **không cần build lại FFmpeg**: chạy `scripts/pack-effects.sh`
(Windows: `scripts\pack-effects.ps1`) rồi dùng file `.zip` mới.

### Test

Test GPU tự bỏ qua (in dòng `skipping: ...`) khi không có adapter phù hợp, nên chạy xanh vẫn có thể sót
phần chưa kiểm: thêm `-- --nocapture` để thấy các dòng đó.

- `GPUFX_TEST_BACKEND=vulkan|dx12|metal|gl` chọn cố định backend (mặc định: backend tốt nhất). Trên Windows
  chạy bộ test hai lần, một lần `vulkan` và một lần `dx12`.
- Test shader cache D3D12 cần `dxcompiler.dll` trên `PATH`, thiếu thì bị bỏ qua. Lấy bằng
  `scripts/fetch-dxc.sh build/dxc` rồi thêm `build/dxc` vào `PATH`.
- CI chạy bộ test trên lavapipe (Linux, Vulkan) và Metal (macOS). Trên Windows CI chỉ chạy fmt và clippy:
  WARP, adapter duy nhất của runner hosted, chạy shader bằng CPU và mất nhiều phút, nên test D3D12 chạy
  trên GPU của máy local. Metal có thể làm tròn một mẫu YUV lệch một bậc
  so với đường CPU, test YUV chỉ chấp nhận điều này trên Metal.

### Những gì chưa được kiểm

- **macOS**: không có máy Mac; chỉ chạy `cargo test` trên runner macOS của CI (Metal). Đường frame VideoToolbox của
  filter mới chỉ được biên dịch (kiểm chéo từ Windows); job CI `ffmpeg-macos` build FFmpeg kèm nó và chạy
  `test-bundle.sh` nhưng chưa chạy lần nào, và runner hosted có thể không có adapter Metal dùng được (khi đó
  test bị bỏ qua kèm cảnh báo). Chưa có bản build macOS để tải.
- **Linux trên GPU thật**: Linux mới chạy trên lavapipe (Vulkan phần mềm), trong CI và máy ảo. Frame Vulkan
  dùng chung với FFmpeg mới chạy trên GPU thật ở Windows.
- **OpenGL**: wgpu có hỗ trợ nhưng chưa có test hay job CI nào chạy trên nó.

### Build nhanh trên bản FFmpeg build sẵn (khuyên dùng)

Lấy bản FFmpeg 9.0 shared build sẵn từ
[tqk2811/FFmpegBuild](https://github.com/tqk2811/FFmpegBuild/releases), chỉ build lại
`libavfilter` (gpufx + danh sách filter rút gọn) rồi thay vào gói. `ffmpeg`, `ffprobe` và
các thư viện còn lại (`avcodec`, `avformat`…) giữ nguyên bản build sẵn. Mất vài phút:

```sh
scripts/build-prebuilt.sh            # linux64 -> dist/linux64
scripts/build-prebuilt.sh win64      # cross-compile bằng mingw-w64 -> dist/win64
scripts/test-bundle.sh dist/linux64  # chạy mọi hiệu ứng qua ffmpeg, kể cả quy tắc báo lỗi
```

Cần cargo, gcc, make, pkg-config, curl, patchelf (win64 thêm `mingw-w64`, `unzip` và Rust
target `x86_64-pc-windows-gnu`). Đổi bản build sẵn bằng biến `FFBUILD_TAG`,
`FFBUILD_VERSION`, `FFBUILD_LICENSE` (`lgpl`, `gpl`, `lgpl2`, `gpl2`).

`libavfilter` phải build từ **đúng commit** của bản build sẵn để khớp ABI với các thư viện
kia. Submodule `external/FFmpeg` được ghim vào commit đó (`n9.0-2-g03d9533176`, nhánh
`release/9.0`); script dừng lại nếu hai bên lệch nhau. `ffmpeg` tìm filter theo tên lúc chạy
nên không quan tâm `libavfilter` có bao nhiêu filter. Lệnh nào gọi filter đã bị bỏ thì chỉ lệnh
đó báo `No such filter`.

Lưu ý với bản này:
- Chỉ còn các filter trong [docker/keep-filters.txt](docker/keep-filters.txt) cùng `gpufx`: filter nối
  graph (`scale`, `format`, `trim`, `split`, `sendcmd`…) và filter chuẩn hoá đầu vào: thời gian, metadata,
  bố cục, khử xen kẽ và không gian màu (`fps`, `setpts`, `setsar`, `setdar`, `settb`, `setrange`, `setparams`,
  `pad`, `concat`, `select`, `loop`, `reverse`, `yadif`, `bwdif`, `colorspace`, `showinfo`), cùng audio cơ bản (`volume`, `amix`, `adelay`,
  `afade`, `atempo`…). `hwupload`, `hwdownload`, `hwmap` được giữ cho frame Vulkan, D3D12 và D3D11. Filter hình (`drawtext`,
  `overlay`, `gblur`…) và các filter hw khác (`scale_cuda`, `scale_vulkan`…) không còn. Cần filter nào thì thêm
  tên vào file đó rồi build lại.
- Frame Vulkan cần `libavutil` build sẵn có Vulkan (bản phát hành FFmpegBuild có) và Vulkan-Headers của Khronos,
  script tự clone (tag `v1.4.321`, hoặc `VULKAN_HEADERS=<thư mục>`); thiếu thì filter được build không có frame
  Vulkan và script báo điều đó.
- win64: frame D3D12/D3D11 cần d3d12va/d3d11va trong `libavutil` build sẵn (bản FFmpegBuild có); libavfilter
  được configure với `--enable-d3d11va --enable-d3d12va`, tải `d3d12video.h` của mingw-w64 v12.0.0 khi mingw-w64
  đã cài không có.
- `ffmpeg` in `WARNING: library configuration mismatch` ở banner (hoặc khi bỏ
  `-hide_banner`), vì `libavfilter` được configure khác các thư viện còn lại. Cảnh báo này vô hại.
- `lib/pkgconfig/libavfilter.pc`, header và import lib vẫn là của bản build sẵn (không biết
  tới gpufx). Gói dùng để chạy `ffmpeg`, không dùng để link chương trình khác với `libavfilter`.
- win64: `avfilter-12.dll` và `gpufx.dll` dùng `msvcrt.dll`, còn DLL build sẵn dùng UCRT.
  FFmpeg cấp phát và giải phóng bộ nhớ qua `avutil` nên chạy được; CI chạy thử trên Windows.

### Build FFmpeg đầy đủ từ mã nguồn (Docker)

Build cả FFmpeg từ submodule `external/FFmpeg` (cùng commit 9.0 ở trên), chậm hơn nhiều.
Script build trong Docker theo kiểu
[BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds), chỉ cần Docker và git:

```sh
./build.sh            # linux64
./build.sh win64      # cross-compile cho Windows bằng mingw-w64
./build.sh all
```

Trên Windows (Docker Desktop): `.\build.ps1` (mặc định win64).

Kết quả nằm trong `dist/<target>/`:

```
bin/      ffmpeg, ffprobe, libgpufx.so | gpufx.dll, gpufx-cli
effects/  các hiệu ứng mẫu đã đóng gói .zip
include/  gpufx.h
```

Bản build này **tắt toàn bộ filter video có sẵn của FFmpeg** (overlay, drawtext, gblur...).
Hiệu ứng video đến từ gói `gpufx`. Filter audio được giữ nguyên, và một số filter video tối
thiểu mà ffmpeg CLI hoặc gpufx cần vẫn được giữ (`scale`, `format`, `trim`, `split`,
`sendcmd`...). Danh sách nằm ở [docker/keep-filters.txt](docker/keep-filters.txt), sửa file
này để thêm/bớt. Codec dùng bộ có sẵn của FFmpeg; chưa kèm thư viện ngoài như x264.

Lần build sau nhanh hơn ở phần Rust nhờ Docker volume `gpufx-work-<target>` và `gpufx-cargo-registry`; FFmpeg được build lại từ đầu mỗi lần cho sạch.

### Tự tích hợp vào cây FFmpeg khác

```sh
scripts/install-libgpufx.sh "$HOME/.local/gpufx"          # libgpufx + gpufx.h + gpufx.pc
ffmpeg/integrate.sh /path/to/FFmpeg                       # thêm vf_gpufx.c, sửa configure
cd /path/to/FFmpeg
PKG_CONFIG_PATH="$HOME/.local/gpufx/lib/pkgconfig" ./configure --enable-libgpufx
make -j"$(nproc)"
```

## Cấu trúc

| Thư mục | Nội dung |
|---------|----------|
| `crates/gpufx-core` | Engine: đọc gói, manifest, tham số, biên dịch và chạy shader |
| `crates/gpufx-ffi` | `libgpufx` với C ABI (`include/gpufx.h`) |
| `crates/gpufx-cli` | Lệnh `gpufx info / check / pack / run` |
| `ffmpeg/` | Filter `vf_gpufx.c` và script tích hợp |
| `external/FFmpeg` | Submodule mã nguồn FFmpeg |
| `docker/`, `build.sh`, `build.ps1` | Build FFmpeg + gpufx một lệnh trong Docker |
| `examples/effects/` | 36 hiệu ứng mẫu |
| `scripts/` | `build-prebuilt.sh` (build nhanh trên FFmpeg build sẵn), `test-bundle.sh`, `install-libgpufx.sh`, `pack-effects.sh`/`.ps1` (đóng gói zip) |

## Giấy phép

Mã nguồn của repo dùng giấy phép [MIT](LICENSE), trừ các phần sau:

| Phần | Giấy phép |
|------|-----------|
| `ffmpeg/vf_gpufx.c` (filter, được build vào `libavfilter`) | LGPL 2.1 trở lên, giống FFmpeg |
| `external/FFmpeg` (submodule) và thư viện FFmpeg trong bản build | Giấy phép của FFmpeg: `scripts/build-prebuilt.sh` mặc định LGPL v3 (`lgpl`), `lgpl2` là LGPL 2.1; bản build Docker (`build.sh`) là LGPL 2.1 trở lên; bản `gpl`/`gpl2` dùng GPL. Giấy phép thực tế là file `LICENSE.txt`/`FFMPEG-LICENSE.txt` đi kèm bản build |
| Ảnh lá của `falling-maple` | Apache 2.0 (Noto Emoji, Google) |
| Ảnh lá của `falling-ginkgo` | CC BY 3.0 (game-icons.net, Delapouite) |
| `bin/dxcompiler.dll` trong bản win64 (DirectX Shader Compiler, Microsoft) | LLVM (University of Illinois/NCSA), MIT và điều khoản DXC của Microsoft: `bin/LICENSE-dxcompiler-*.txt`. Là DLL riêng, wgpu nạp lúc chạy; xoá nó thì dùng FXC |

Nguồn và giấy phép của ảnh lá ở [assets/leaves/README.md](assets/leaves/README.md).

Thư viện `libgpufx` và các hiệu ứng mẫu dùng được trong phần mềm đóng nguồn, nhưng phải kèm
thông báo bản quyền: MIT của repo, Apache 2.0 / CC BY 3.0 nếu dùng hai hiệu ứng lá, và giấy
phép của các crate Rust mà `libgpufx` liên kết (file `THIRD-PARTY-LICENSES-gpufx.txt` trong bản build, sinh bằng `cargo about`;
CI kiểm giấy phép crate bằng `cargo deny check licenses`, xem `deny.toml`).

Khi phân phối bản build kèm FFmpeg, bạn phải tuân theo giấy phép của FFmpeg: kèm nội dung giấy
phép và thông báo bản quyền, để người dùng thay được thư viện (bản build là shared library), và
cung cấp mã nguồn FFmpeg đã dùng, gồm cả `vf_gpufx.c` và `ffmpeg/integrate.sh`. Bản `gpl`/`gpl2`
thì toàn bộ FFmpeg trong bản build là GPL. Xem thêm https://ffmpeg.org/legal.html (đây không
phải tư vấn pháp lý).
