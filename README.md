# FFmpegFilterExtend (gpufx)

Hiệu ứng video chạy bằng **shader trên GPU** cho FFmpeg, nạp từ **gói `.zip`** bên ngoài
(kiểu CapCut). FFmpeg chỉ cần build một lần với filter `gpufx`; hiệu ứng mới là gói zip mới.

- Shader **WGSL** hoặc **GLSL**, nhiều pass, nhiều input, texture đi kèm, tham số tự sinh.
- Chạy trên **Vulkan, DirectX 12, Metal, OpenGL** (qua [wgpu](https://wgpu.rs)), Windows/Linux/macOS.
- Tham số là literal hoặc biểu thức theo thời gian; đổi lúc chạy bằng `sendcmd`.
- Gói khai báo **quy tắc input/output** (pixel format, kích thước, cùng kích thước giữa
  các input); stream không khớp thì báo lỗi rõ ràng thay vì chuyển đổi ngầm.
- 20 hiệu ứng mẫu: chỉnh màu, đen trắng, sepia, sharpen, pixelate, chroma key,
  picture-in-picture, chuyển cảnh (crossfade, slide, wipe, circle)...

```sh
ffmpeg -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect=wipe-transition.zip:params='progress=clip((t-1)/1.5\,0\,1)|angle=45'" out.mp4
```

Tài liệu: [thiết kế](docs/DESIGN.md) · [định dạng gói và cách viết shader](docs/EFFECT_FORMAT.md)

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
- Chỉ còn các filter trong [docker/keep-filters.txt](docker/keep-filters.txt) cùng `gpufx`.
  Filter audio như `volume`, `amix`, filter hw (`hwupload`, `scale_cuda`…), `setpts`, `fps`
  đều không còn. Cần filter nào thì thêm tên vào file đó rồi build lại.
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
| `examples/effects/` | 20 hiệu ứng mẫu |
| `scripts/` | `build-prebuilt.sh` (build nhanh trên FFmpeg build sẵn), `test-bundle.sh`, `install-libgpufx.sh`, `pack-effects.sh`/`.ps1` (đóng gói zip) |
