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

### FFmpeg với filter `gpufx` (FFmpeg 9.0)

```sh
scripts/install-libgpufx.sh "$HOME/.local/gpufx"          # libgpufx + gpufx.h + gpufx.pc
git clone --branch n9.0.2 --depth 1 https://github.com/FFmpeg/FFmpeg
ffmpeg/integrate.sh FFmpeg                                # thêm vf_gpufx.c, sửa configure
cd FFmpeg
PKG_CONFIG_PATH="$HOME/.local/gpufx/lib/pkgconfig" ./configure --enable-libgpufx \
  --extra-ldflags="-Wl,-rpath,$HOME/.local/gpufx/lib"
make -j"$(nproc)"
./ffmpeg -h filter=gpufx
```

## Cấu trúc

| Thư mục | Nội dung |
|---------|----------|
| `crates/gpufx-core` | Engine: đọc gói, manifest, tham số, biên dịch và chạy shader |
| `crates/gpufx-ffi` | `libgpufx` với C ABI (`include/gpufx.h`) |
| `crates/gpufx-cli` | Lệnh `gpufx info / check / pack / run` |
| `ffmpeg/` | Filter `vf_gpufx.c` và script tích hợp |
| `examples/effects/` | 5 hiệu ứng mẫu |
