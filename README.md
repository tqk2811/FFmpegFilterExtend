# FFmpegFilterExtend (gpufx)

Hiệu ứng video chạy bằng **shader trên GPU** cho FFmpeg, nạp từ **gói `.zip`** bên ngoài
(kiểu CapCut). FFmpeg chỉ cần build một lần với filter `gpufx`; hiệu ứng mới là gói zip mới.

- Shader **WGSL** hoặc **GLSL**, nhiều pass, nhiều input, texture đi kèm, tham số tự sinh.
- Chạy trên **Vulkan, DirectX 12, Metal, OpenGL** (qua [wgpu](https://wgpu.rs)), Windows/Linux/macOS.
- Tham số là literal hoặc biểu thức theo thời gian; đổi lúc chạy bằng `sendcmd`.

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
```

### Build FFmpeg kèm gpufx bằng một lệnh (Docker)

FFmpeg nằm trong submodule `external/FFmpeg` (nhánh master, đang là 9.1-dev; sẽ trỏ sang
tag `n9.1` khi FFmpeg phát hành). Script build trong Docker theo kiểu
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
| `examples/effects/` | 5 hiệu ứng mẫu |
