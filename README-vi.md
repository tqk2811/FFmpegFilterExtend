# FFmpegGpuFilter (gpufx)

Hiệu ứng video chạy bằng **shader trên GPU** cho FFmpeg, nạp từ **gói `.zip`** bên ngoài
(kiểu CapCut). FFmpeg chỉ cần build một lần với filter `gpufx`; hiệu ứng mới là gói zip mới.

- Shader **WGSL** hoặc **GLSL**, nhiều pass, nhiều input, texture đi kèm, tham số tự sinh.
- Chạy trên **Vulkan, DirectX 12, Metal, OpenGL** (qua [wgpu](https://wgpu.rs)), Windows/Linux/macOS.
- Tham số là literal hoặc biểu thức theo thời gian; đổi lúc chạy bằng `sendcmd`.
- Nhiều hiệu ứng trong một filter (`effect='blur.zip|vignette.zip'`): frame lên GPU một lần,
  chạy hết chuỗi rồi mới về RAM.
- Cả **đồ thị hiệu ứng** trong một filter (`graph='[0]split[a][b]; [a]blur.zip[x]; [x][b]crossfade.zip[out]'`):
  rẽ nhánh, nhiều input và nhiều output, tất cả trong một lần submit GPU; `split` không chép gì và
  texture trung gian lấy từ pool.
- Gói khai báo **quy tắc input/output** (pixel format, kích thước, cùng kích thước giữa
  các input); stream không khớp thì báo lỗi rõ ràng thay vì chuyển đổi ngầm.
- 36 hiệu ứng mẫu: chỉnh màu, đen trắng, sepia, sharpen, pixelate, chroma key,
  picture-in-picture, đặt ảnh vào khung trên nền mờ, lá phong / lá rẻ quạt rơi (ảnh PNG trong gói), chuyển cảnh (crossfade, slide, wipe, circle, clock, collapse, expand,
  dip to black, dissolve, pixelize, zoom, blinds, bàn cờ, đẩy hộp, cuộn phim, xếp ảnh...)

- Cache shader trên đĩa (tuỳ chọn): `GPUFX_SHADER_CACHE=<thư mục>` (Vulkan; xem [thiết kế](docs/DESIGN-vi.md)).

```sh
ffmpeg -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect=wipe-transition.zip:params='progress=clip((t-1)/1.5\,0\,1)|angle=45'" out.mp4
```

```sh
# upload một lần, đồ thị hình thoi trên GPU, hai output pad ghi ra hai file
ffmpeg -i a.mp4 -i b.mp4 -filter_complex \
  "[0:v][1:v]gpufx=graph='[0]split[a][b]; [a]gaussian-blur.zip[ba]; [b]grayscale.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[x]; [x]split[x1][x2]; [x2][1]wipe-transition.zip[w]':params='x.progress=0.5|w.progress=t'[mix][wipe]" \
  -map "[mix]" mix.mp4 -map "[wipe]" wipe.mp4
```

Tài liệu: [thiết kế](docs/DESIGN-vi.md) · [định dạng gói và cách viết shader](docs/EFFECT_FORMAT-vi.md) · [English](README.md)

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
  `afade`, `atempo`…). Filter hình (`drawtext`, `overlay`, `gblur`…) và filter hw (`hwupload`,
  `scale_cuda`…) không còn. Cần filter nào thì thêm tên vào file đó rồi build lại.
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
phép của các crate Rust mà `libgpufx` liên kết.

Khi phân phối bản build kèm FFmpeg, bạn phải tuân theo giấy phép của FFmpeg: kèm nội dung giấy
phép và thông báo bản quyền, để người dùng thay được thư viện (bản build là shared library), và
cung cấp mã nguồn FFmpeg đã dùng, gồm cả `vf_gpufx.c` và `ffmpeg/integrate.sh`. Bản `gpl`/`gpl2`
thì toàn bộ FFmpeg trong bản build là GPL. Xem thêm https://ffmpeg.org/legal.html (đây không
phải tư vấn pháp lý).
