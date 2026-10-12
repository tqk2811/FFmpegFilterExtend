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
