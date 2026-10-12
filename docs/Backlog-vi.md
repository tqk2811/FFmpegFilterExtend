# Việc còn treo

### Build Docker đầy đủ chưa chạy lại trên FFmpeg 9.0
- **Vấn đề**: submodule `external/FFmpeg` đã chuyển từ master (9.1-dev) về `n9.0-2-g03d9533176`. `build.sh` và job CI `ffmpeg-docker` (chỉ chạy khi bấm tay `workflow_dispatch`) chưa được chạy lại trên commit này.
- **Vị trí**: [build.sh](../build.sh), [docker/build-in-container.sh](../docker/build-in-container.sh), [.github/workflows/ci.yml](../.github/workflows/ci.yml).
- **Vì sao**: `integrate.sh` và `vf_gpufx.c` đã chạy được trên 9.0 qua `scripts/build-prebuilt.sh`, nhưng build đầy đủ (mọi codec, mọi filter audio) chưa ai kiểm lại.
- **Ngày ghi**: 2026-10-12

### win64: lệch CRT giữa `avfilter-12.dll` và bản build sẵn
- **Vấn đề**: `avfilter-12.dll` (mingw-w64 của Ubuntu) và `gpufx.dll` (Rust `x86_64-pc-windows-gnu`) dùng `msvcrt.dll`, còn DLL build sẵn của FFmpegBuild dùng UCRT (`api-ms-win-crt-*`). Chạy được vì FFmpeg cấp phát/giải phóng bộ nhớ qua `avutil` và không truyền `FILE*`/`errno`/locale qua ranh giới DLL. Đây vẫn là giả định, và runner Windows có tìm được adapter phần mềm (WARP) hay không cũng chưa kiểm chứng.
- **Vị trí**: [scripts/build-prebuilt.sh](../scripts/build-prebuilt.sh) (biến `CROSS`), job `ffmpeg-windows` trong [.github/workflows/ci.yml](../.github/workflows/ci.yml).
- **Vì sao**: muốn khớp hẳn thì phải build bằng toolchain mingw UCRT, giống toolchain image BtbN mà FFmpegBuild dùng. Ubuntu noble chưa có gói mingw UCRT.
- **Ngày ghi**: 2026-10-12

### Kiểm checksum bản build sẵn, định dạng version khác
- **Vấn đề**: `build-prebuilt.sh` tải file không kiểm sha256, và dùng lại file trong cache mãi mãi (file hỏng hay bị cắt cụt cũng không phát hiện). Tên file được ghép theo mẫu `ffmpeg-nX.Y-N-g<sha>-<target>-<license>-shared-X.Y`. Tên của các bản `lgpl2`/`gpl2` và bản đặt theo tag trơn chưa được kiểm.
- **Vị trí**: [scripts/build-prebuilt.sh](../scripts/build-prebuilt.sh) (đoạn tải, biến `NAME`).
- **Vì sao**: ghim sha256 theo từng target/license, hoặc đọc file checksum nếu release có, để tránh build trên bản tải lỗi.
- **Ngày ghi**: 2026-10-12

### Commit `76a729f` chưa qua review
- **Vấn đề**: commit thêm quy tắc input/output, 15 hiệu ứng và `pack-effects` được tạo trước khi áp dụng bộ luật. Nó chưa qua lượt agent review và message không theo Conventional Commits. Commit đã push nên không sửa lại lịch sử.
- **Vị trí**: [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c), [crates/gpufx-core/src/manifest.rs](../crates/gpufx-core/src/manifest.rs), [crates/gpufx-ffi/src/lib.rs](../crates/gpufx-ffi/src/lib.rs), `examples/effects/*`.
- **Vì sao**: phần negotiate format và chuyển đổi swscale trong `vf_gpufx.c` là logic phức tạp, nên có một lượt review riêng.
- **Ngày ghi**: 2026-10-12

### Chưa có test cho việc bỏ side data; gray limited range
- **Vấn đề**:
  - `vf_gpufx.c` bỏ side data phụ thuộc màu (mastering display, content light level, ICC…), motion vector và video enc params, nhưng chưa có clip nào mang side data để test. Với input PQ, output vẫn là PQ nhưng mất HDR10 static metadata (đã có cảnh báo HDR).
  - `gray`/`gray10` chưa chuyển trên GPU, vẫn qua swscale, mà swscale luôn coi gray là full range (FIXME trong `libswscale/format.c`), nên gray limited range bị chuyển sai.
  - Input premultiplied dạng float (EXR `gbrapf32`) giờ đi qua swscale sang `rgba64le` rồi GPU mới bỏ premultiply (đã sửa phần lớn: 16 bit thay vì 8 bit), nhưng vẫn mất phần float vượt 16 bit và giá trị ngoài 0..1.
- **Vị trí**: [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`process_frame`, `input_frame`), [crates/gpufx-core/src/frame.rs](../crates/gpufx-core/src/frame.rs).
- **Vì sao**: gray có thể thêm vào `PixelFormat` (một plane, range lấy từ frame) là sửa được; side data cần clip test.
- **Ngày ghi**: 2026-10-12

### P1: các giới hạn còn lại của chuyển YUV trên GPU
- **Vấn đề**:
  - Chỉ có các format trong `PixelFormat` (nv12, p010le, yuv420p/422p/444p, bản 10le, yuva420p/444p, rgba, rgba64le). 12/16 bit, `p016`, `nv21`, `nv16`, `yuva*p10` vẫn qua swscale. Ma trận FCC, SMPTE 240M, YCgCo, BT.2020 constant luminance cũng qua swscale.
  - Mẫu 16 bit được đọc theo little endian: trên máy big endian, `vf_gpufx.c` vẫn đưa tên `...le` nhưng texture upload theo thứ tự byte của máy, nên sai màu. Chưa có máy để thử.
  - Lọc chroma khác swscale (bilinear lên, tam giác xuống): trên cạnh sắc (testsrc2) chênh trung bình khoảng 1.4 mã 8 bit so với swscale. Không có transfer/tonemap: PQ/HLG vẫn coi như SDR.
  - Vị trí chroma không rõ: GPU đoán center cho full range, left cho limited; swscale (đường dự phòng) tự đoán theo cách của nó, có thể khác.
  - Pipeline `rgba16float` của gói được biên dịch lúc gặp frame trên 8 bit đầu tiên (lazy, chưa có API để báo trước độ sâu lúc configure), nên frame đó chậm hơn; output đi qua storage buffer theo plane rồi một buffer map được (thêm một bản output trong bộ nhớ GPU).
  - `gpufx run` (CLI) vẫn đọc/ghi PNG 8 bit, chưa dùng `rgba64le` cho PNG 16 bit.
  - Đo khác biệt trong `scripts/test-bundle.sh` dùng `od`/`awk` trên 3 frame; ngưỡng (trung bình) đặt theo testsrc2, chưa có clip 10-bit mịn để kiểm 10 bit qua `ffmpeg` (test Rust `ten_bit_steps_survive_a_chain` có kiểm).
- **Vị trí**: [crates/gpufx-core/src/convert.rs](../crates/gpufx-core/src/convert.rs), [crates/gpufx-core/src/frame.rs](../crates/gpufx-core/src/frame.rs), [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`gpu_color`, `rgba_for`).
- **Vì sao**: phạm vi B-chung chỉ cần các format thông dụng; phần còn lại thêm dần khi có nhu cầu.
- **Ngày ghi**: 2026-10-12

### Cache gói: khoá toàn cục khi nạp, không phát hiện file đổi
- **Vấn đề**:
  - Cache gói trong `gpufx-ffi` giữ một khoá suốt lúc đọc và biên dịch gói, nên hai thread mở hai gói *khác nhau* cùng lúc phải chờ nhau. FFmpeg gọi `init` trên một thread nên chưa ảnh hưởng; app nhiều thread thì chậm hơn.
  - Theo yêu cầu, cache không kiểm tra file đổi (mtime/kích thước). Nếu sau này làm hot-reload (M1) thì cần thêm mtime vào khoá.
- **Vị trí**: [crates/gpufx-ffi/src/lib.rs](../crates/gpufx-ffi/src/lib.rs) (`program`).
- **Vì sao**: chưa cần cho FFmpeg; đổi sang khoá theo từng gói khi có app dùng nhiều thread.
- **Ngày ghi**: 2026-10-12

### Ảnh PNG trong gói không bị giới hạn kích thước
- **Vấn đề**: PNG trong `textures` không được kiểm tra kích thước khi nạp. Ảnh lớn hơn giới hạn của device (thường 8192) gây wgpu uncaptured error, mặc định là panic và có thể làm sập process FFmpeg. Cũng không có giới hạn kích thước sau khi giải nén, nên một PNG nhỏ có thể giải ra ảnh rất lớn.
- **Vị trí**: [crates/gpufx-core/src/runtime.rs](../crates/gpufx-core/src/runtime.rs) (`Program::new`).
- **Vì sao**: phát hiện khi nghiên cứu kế hoạch sprite ([Plan-sprites-vi.md](Plan-sprites-vi.md), G4); sẽ sửa ở bước 2 của kế hoạch đó.
- **Ngày ghi**: 2026-10-12

### Bản build chưa kèm giấy phép của các crate Rust
- **Vấn đề**: `libgpufx` liên kết tĩnh wgpu, naga, image, zip… Giấy phép của các crate này (MIT, Apache-2.0, BSD, Zlib, có thể cả MPL-2.0, Unicode-3.0) yêu cầu kèm thông báo khi phân phối bản nhị phân, nhưng bản build `dist/<target>` và pre-release chưa có file tổng hợp giấy phép bên thứ ba.
- **Vị trí**: [scripts/build-prebuilt.sh](../scripts/build-prebuilt.sh), CI pre-release.
- **Vì sao**: cần thêm bước sinh `THIRD-PARTY-LICENSES` (ví dụ `cargo about`) và `cargo deny check licenses` trong CI để không có crate GPL lọt vào.
- **Ngày ghi**: 2026-10-12

### Thu nhỏ input không có mipmap: răng cưa khi ảnh lớn hơn khung nhiều
- **Vấn đề**: sampler tuyến tính, texture input không có mip. Khi hiệu ứng thu nhỏ input nhiều lần (ảnh 4000 px trong `fit`, hộp nhỏ của `push-box`, ảnh của `photo-collection`), ảnh bị răng cưa/nhấp nháy. Nền mờ của `fit` dùng 64 tap bilinear rải đều trên bán kính, nên bán kính lớn (trên khoảng 64 px) có thể lộ bóng lặp.
- **Vị trí**: [crates/gpufx-core/src/runtime.rs](../crates/gpufx-core/src/runtime.rs) (`create_texture`, sampler), `examples/effects/{fit,push-box,photo-collection}`.
- **Vì sao**: cần tuỳ chọn mipmap cho input (sinh mip trên GPU mỗi frame) hoặc pass thu nhỏ trước; làm cùng bước mipmap của [Plan-sprites-vi.md](Plan-sprites-vi.md).
- **Ngày ghi**: 2026-10-12
