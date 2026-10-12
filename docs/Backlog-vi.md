# Việc còn treo

### Line ending của file mới (CRLF hay LF)
- **Vấn đề**: luật chung của người dùng yêu cầu file mới (trừ script shell, Dockerfile, Makefile) ghi CRLF, nhưng toàn bộ repo hiện là LF, kể cả `.ps1`, `.md`, `.json`, `.wgsl`. `.gitattributes` mới chỉ quy định `*.sh` và `*.Dockerfile`.
- **Vị trí**: [.gitattributes](../.gitattributes), mọi file text.
- **Vì sao**: trộn hai kiểu xuống dòng làm diff phình. Cần chốt một kiểu rồi ghi vào `.gitattributes` (vd `* text=auto eol=crlf` cùng ngoại lệ LF cho `*.sh`, `*.Dockerfile`, `Makefile`).
- **Ngày ghi**: 2026-10-12

### Hậu tố `-vi` cho tài liệu tiếng Việt
- **Vấn đề**: theo quy tắc đặt tên Markdown, file không phải tiếng Anh phải có hậu tố ngôn ngữ (`-vi`). Hiện `README.md`, `docs/DESIGN.md`, `docs/EFFECT_FORMAT.md` viết tiếng Việt nhưng chưa có hậu tố.
- **Vị trí**: [README.md](../README.md), [docs/DESIGN.md](DESIGN.md), [docs/EFFECT_FORMAT.md](EFFECT_FORMAT.md).
- **Vì sao**: đổi tên `README.md` thì GitHub không còn tự hiển thị README. Cần chọn: giữ `README.md` tiếng Anh ngắn và trỏ sang `README-vi.md`, hoặc chỉ đổi tên hai file trong `docs/`. Đổi tên xong phải sửa mọi link trỏ tới.
- **Ngày ghi**: 2026-10-12

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

### Chưa có test cho việc bỏ side data; gray limited range; độ chính xác alpha float
- **Vấn đề**:
  - `vf_gpufx.c` bỏ side data phụ thuộc màu (mastering display, content light level, ICC…), motion vector và video enc params, nhưng chưa có clip nào mang side data để test. Với input PQ, output vẫn là PQ nhưng mất HDR10 static metadata (đã có cảnh báo HDR).
  - swscale luôn coi gray là full range (FIXME trong `libswscale/format.c`), nên gray limited range bị chuyển sai.
  - Input premultiplied dạng float (EXR `gbrapf32`) bị hạ về 8 bit trước khi bỏ premultiply, nên điểm ảnh alpha thấp mất độ chính xác màu.
- **Vị trí**: [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`process_frame`, `input_image`, `unpremultiply`).
- **Vì sao**: sẽ xử lý cùng pipeline trên GPU (YUV/float trên GPU, `rgba16float`) ở bước B-chung của kế hoạch.
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

### `globals.time` là f32: chuyển động giật khi timestamp rất lớn
- **Vấn đề**: runtime ép thời gian về `f32` trước khi gửi lên shader. Với hiệu ứng lá rơi ở 30 fps: t = 3600 s sai số 0,03 px (không thấy), t = 86400 s (1 ngày) bước thời gian mỗi frame lệch ±17 %, vị trí lệch khoảng 1 px; t = 360000 s lệch khoảng 6 px. Ảnh hưởng mọi hiệu ứng dùng `globals.time`, kể cả khi dùng `offset` lớn.
- **Vị trí**: [crates/gpufx-core/src/runtime.rs](../crates/gpufx-core/src/runtime.rs) (`process`, `time as f32`), `examples/effects/falling-*/shaders/leaves.wgsl`.
- **Vì sao**: cần đổi globals (thêm giây nguyên `u32` + phần lẻ `f32`, hoặc `time_ms: u32`), tức là đổi định dạng prelude; làm cùng A2 (API v3).
- **Ngày ghi**: 2026-10-12
