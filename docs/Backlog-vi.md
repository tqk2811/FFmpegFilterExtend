# Việc còn treo

### [Thấp] Lỗi `out_format` trên D3D liệt kê `rgba` dù FFmpeg không làm được frame đó
- **Vấn đề**: `out_format=rgba` trên D3D12/D3D11 hỏng với `Unsupported pixel format: rgba` từ FFmpeg, nhưng thông báo của gpufx vẫn liệt kê `nv12, p010le, rgba, rgba64le` là ghi được. Bộ frame D3D12 của FFmpeg chỉ có `nv12`/`p010` ([hwcontext_d3d12va.c:71](../external/FFmpeg/libavutil/hwcontext_d3d12va.c#L71)); D3D11 có `bgra` chứ không có `rgba`.
- **Vị trí**: `sw_format_list` ở [vf_gpufx.c:1166](../ffmpeg/vf_gpufx.c#L1166), dùng ở các thông báo dòng 1216, 1356, 1361.
- **Vì sao**: người dùng thử `rgba` theo gợi ý rồi gặp lỗi khó hiểu; nên nói rõ định dạng nào FFmpeg làm được trên API đó, và gợi ý `alpha-extract` khi cần alpha. Cần build lại FFmpeg để kiểm.
- **Ngày ghi**: 2026-10-16

### [Thấp] Test box-in chưa phủ direction 1 và 3
- **Vấn đề**: test chỉ thử `direction` 0 và 2; đảo dấu riêng ở nhánh 1/3 không bị bắt.
- **Vị trí**: [crates/gpufx-core/tests/effects.rs](../crates/gpufx-core/tests/effects.rs) (`transition_modes_have_clean_endpoints_and_their_own_midpoint`), [box_in.wgsl](../examples/effects/slideshow/box-in/shaders/box_in.wgsl).
- **Vì sao**: rẻ để thêm, chặn hồi quy chiều chạy.
- **Ngày ghi**: 2026-10-16

### [Thấp] Báo lỗi host_image_copy cho FFmpeg/Intel; gỡ phần né khi đã sửa
- **Vấn đề**: FFmpeg 9 bật `VK_EXT_host_image_copy`; driver Intel Windows (101.7082) cấp phát hỏng ảnh optimal một plane (`VK_ERROR_OUT_OF_HOST_MEMORY`) và copy sai chroma của ảnh multi-planar. Đã báo FFmpeg: https://code.ffmpeg.org/FFmpeg/FFmpeg/issues/25063; đã báo Intel: https://github.com/IGCIT/Intel-GPU-Community-Issue-Tracker-IGCIT/issues/1587. gpufx đang né: bỏ cờ `VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT` khỏi frames context của mình (dựa vào cách `hwcontext_vulkan.c` của FFmpeg 9.0 đọc `usage`: kiểm lại mỗi khi nâng FFmpeg; frame của filter Vulkan khác như `scale_vulkan` cũng bị từ chối dù có thể đúng) và từ chối frame `hwupload` trên driver đó; `test-bundle.sh` đổi sang `gpufx_upload` khi gặp driver này.
- **Vị trí**: [ffmpeg/vf_gpufx_vk.h](../ffmpeg/vf_gpufx_vk.h) (`gpufx_hwframe_ctx_init`, `gpufx_vk_host_copy_broken`), [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (kiểm input Vulkan trong `config_vulkan`), [scripts/test-bundle.sh](../scripts/test-bundle.sh) (`INTEL_HIC`), [docs/INTEL_VULKAN-vi.md](INTEL_VULKAN-vi.md).
- **Vì sao**: gửi báo lỗi để FFmpeg/Intel sửa; khi driver hoặc FFmpeg đã sửa thì bỏ lệnh từ chối (đang chặn cả người dùng driver mới) và nhánh `INTEL_HIC` trong test.
- **Ngày ghi**: 2026-10-14

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

### Hiệu ứng thu nhỏ ảnh chưa dùng mipmap của input
- **Vấn đề**: engine đã có `"mipmaps": true` cho input (api 2, chuỗi mip sinh trên GPU mỗi frame), nhưng `fit`, `push-box`, `photo-collection` vẫn lấy mẫu ở mức 0, nên ảnh lớn hơn khung nhiều (ảnh 4000 px trong `fit`, hộp nhỏ của `push-box`) vẫn răng cưa/nhấp nháy. Nền mờ của `fit` dùng 64 tap bilinear rải đều trên bán kính, bán kính lớn (trên khoảng 64 px) có thể lộ bóng lặp; đọc từ mức mip phù hợp sẽ hết.
- **Vị trí**: `examples/effects/slideshow/{fit,push-box,photo-collection}`, [crates/gpufx-core/src/mips.rs](../crates/gpufx-core/src/mips.rs).
- **Vì sao**: giữ output của các hiệu ứng cũ giống từng byte khi thêm tính năng; chuyển sang api 2 và tự tính `lod` theo tỉ lệ thu nhỏ là thay đổi output, cần làm và kiểm riêng. Mip của input tốn thêm khoảng 1/3 VRAM của texture đó và một pass mỗi mức mỗi frame.
- **Ngày ghi**: 2026-10-13

### Sprite/hạt: các phần để sau
- **Vấn đề**:
  - Chưa có hạt có trạng thái (storage buffer giữ giữa các frame, `globals.dt`, reset khi `t` lùi): va chạm, lá đọng trên vật thể, gió đổi theo thời gian. Phải giữ đúng khi seek nên cần thiết kế riêng.
  - Mỗi pass tối đa khoảng 256 hạt (bộ nhớ workgroup 16 KiB). Hàng nghìn hạt cần lọc theo tile 8×8 (`atomicAdd` vào shared memory) hoặc pass ghi buffer hạt (cần output khác kích thước/format, M1).
  - Chưa có thư viện `#include` dùng chung (`gpufx_hash`...): hai gói lá chép cùng `leaves.wgsl` (có test giữ hai bản giống nhau).
  - Trường `colorspace` (`srgb`/`linear`) cho texture chưa có; khi pipeline chuyển sang linear thì phải linear hoá trước `premultiply` (hàm `premultiply` trong `texture.rs` là chỗ duy nhất đổi màu).
  - Mip của texture gói sinh trên CPU khi nạp (resize Triangle từ mức trên): ảnh lớn nhiều layer làm nạp gói chậm hơn; có thể chuyển sang GPU như mip của input.
- **Vị trí**: [crates/gpufx-core/src/texture.rs](../crates/gpufx-core/src/texture.rs), `examples/effects/standalone/falling-*`.
- **Vì sao**: ngoài phạm vi kế hoạch sprite (đã xong: texture mảng, mipmap, premultiply, quỹ đạo `expr`).
- **Ngày ghi**: 2026-10-13

### Tham số `expr`: các giới hạn còn lại
- **Vấn đề**:
  - Biểu thức đổi thì hiệu ứng biên dịch lại pipeline của nó (vài ms, trên llvmpipe lâu hơn) ngay trong lần xử lý frame kế tiếp; biến thể `rgba16float` biên dịch khi cần. Pipeline riêng không được chia sẻ giữa các hiệu ứng có cùng biểu thức.
  - Trong `vf_gpufx.c`, khi Rust từ chối chuỗi thì filter thử parse như biểu thức FFmpeg theo `t`; chuỗi FFmpeg chấp nhận mà Rust không (ví dụ hàm `random`) chỉ báo lỗi ở frame đầu ("expression parameter ... not numbers"), không phải lúc cấu hình.
  - Chưa có biến kiểu vector, so sánh, `if`; hàm luôn trả `f32`.
- **Vị trí**: [crates/gpufx-core/src/expr.rs](../crates/gpufx-core/src/expr.rs), [crates/gpufx-core/src/runtime.rs](../crates/gpufx-core/src/runtime.rs) (`Effect::sync_exprs`), [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`apply_params`).
- **Vì sao**: đủ cho quỹ đạo lá rơi; C ABI cần hàm báo kiểu tham số để `vf_gpufx.c` không thử av_expr với tham số `expr`.
- **Ngày ghi**: 2026-10-13

### Đồ thị GPU: các giới hạn còn lại
- **Vấn đề**:
  - framesync của FFmpeg chỉ nhìn output 0 (`ff_framesync_init` assert một output, nên `vf_gpufx.c` gọi nó khi mới có pad đầu). `activate()` tự xin frame từ input khi output khác muốn frame, và đóng các output còn lại khi output 0 đóng. Output 0 đóng trước (ví dụ `-frames:v` chỉ trên file của output 0) thì mọi output dừng.
  - Output đã đóng (output khác 0) vẫn được tính trên GPU mỗi frame, chỉ bỏ frame đi; nên bỏ output đó khỏi lần chạy (tốn ít VRAM/thời gian hơn).
  - framesync chỉ cấu hình một lần cho mỗi instance filter (output đầu tiên được configure làm việc đó); configure lại link (đổi graph lúc chạy bằng API) chưa được xử lý.
  - Không có danh sách output riêng: nhãn không ai đọc là output, nên nhãn gõ sai thành output pad thừa (FFmpeg báo pad chưa nối, chưa nói rõ nhãn nào).
  - pts, thời lượng và thuộc tính frame (side data, field order) của mọi output lấy từ input 0, kể cả output có kích thước của input khác; cảnh báo SAR vẫn so với input 0.
  - Khi `enable=` tắt filter, chỉ đi tắt (clone frame) nếu mọi output đều trùng format với input nguồn; còn lại tất cả qua `gpufx_effect_convert_graph`.
  - Đường dẫn gói trong `graph=` không được chứa `[`, `]`, `;`, `|`. `memory_plan`/`MemoryStats` chỉ có trong Rust, chưa có trong C API và chưa log trong `vf_gpufx.c`.
  - Pool texture riêng cho từng filter `gpufx`; hai filter cạnh nhau không dùng chung.
- **Vị trí**: [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`init`, `activate`, `process_frame`), [crates/gpufx-core/src/graph.rs](../crates/gpufx-core/src/graph.rs).
- **Vì sao**: muốn các output độc lập thật thì phải tự viết đồng bộ frame thay framesync (hoặc framesync có hỗ trợ nhiều output); số liệu VRAM nên hiện ra cho người dùng (log verbose hoặc hàm C).
- **Ngày ghi**: 2026-10-12

### Cache shader: Metal `metallib`, ký gói cho shader biên dịch sẵn
- **Vấn đề**: cache DXIL của D3D12 và `gpufx pack --precompile` (thư mục `compiled/dx12/`) đã có, còn lại:
  - Metal: wgpu 30 không có cache ra đĩa; `metallib` cần `xcrun metal`, chỉ làm được khi pack trên macOS (không có thì runtime tự biên dịch MSL).
  - Ký gói (`signature`, DESIGN mục 7): hiện DXIL trong gói chỉ được dùng khi đặt `GPUFX_TRUST_PRECOMPILED=1` cho cả process; gói đã ký nên được tin mà không cần biến môi trường (TODO ở `trust_precompiled`).
  - Cách tin tạm trước khi có chữ ký: allowlist SHA-256 theo từng gói; chỉ tin gói nằm trong thư mục mà chỉ user hiện tại ghi được; khi máy có DXC thì biên dịch lại rồi so với blob trong gói.
  - Blob biên dịch sẵn chỉ phủ tham số `expr` mặc định; giá trị khác vẫn biên dịch lúc chạy.
  - Không có negative cache cho blob mà driver cũ từ chối: mỗi lần chạy lại thử blob đó rồi mới đi đường thường.
- **Vị trí**: [crates/gpufx-core/src/shader_cache.rs](../crates/gpufx-core/src/shader_cache.rs) (`trust_precompiled`, `dxil_pipeline`, `precompile`), [crates/gpufx-core/src/package.rs](../crates/gpufx-core/src/package.rs) (`Package::pack`).
- **Vì sao**: passthrough shader không được wgpu kiểm tra (bytecode lạ có thể làm sập driver), nên biến môi trường toàn process là cách tin thô; Metal hiện vẫn biên dịch lại mỗi lần chạy.
- **Ngày ghi**: 2026-10-13

### Frame Vulkan: các giới hạn còn lại
- **Vấn đề**:
  - Chỉ nhận mỗi plane một `VkImage` (`disable_multiplane=1`). Image multiplane (mặc định của FFmpeg cho nv12, p010, yuv420p… khi driver hỗ trợ) bị từ chối; muốn nhận thì cần view từng plane (wgpu có `TEXTURE_FORMAT_NV12`/`P010` cho 2 plane, chưa có cho 3 plane) hoặc tự tạo `VkImageView` theo aspect.
  - FFmpeg 9.0 mặc định tạo frames context `yuva420p`/`yuva444p` không có usage nào (`AVVulkanFramesContext.usage` = 0): output Vulkan của gpufx không thể là các format đó (chuyển sang format khác của manifest, ví dụ `rgba`), input có frames context như vậy bị từ chối (frame của `hwupload` thì dùng được).
  - Output ghi tại chỗ mà hiệu ứng khác cũng đọc thì vẫn copy-out; có thể ghi thẳng nếu frames context của output có `SAMPLED` (thêm `TEXTURE_BINDING` khi import, [vulkan.rs:699](../crates/gpufx-core/src/vulkan.rs#L699)). Graph deep (p010, rgba64…) vẫn copy cả hai đầu.
  - Frame của decoder Vulkan (`-hwaccel vulkan`) là image multiplane nên bị từ chối lúc configure: cần copy trên GPU sang image từng plane (hoặc hỗ trợ view multiplane) mới dùng được; hiện phải `hwdownload,hwupload`. Đường barrier thô cho layout lạ có sẵn nhưng chưa có test.
  - Struct feature chỉ có trong extension mà FFmpeg không đưa vào chuỗi tạo device đọc thành false; struct không có trong bảng của `vulkan.rs` thì giữ giá trị của driver (bảng theo wgpu-hal 30, phải cập nhật khi nâng wgpu).
  - Submit bị wgpu từ chối làm device dùng chung không dùng được cho frame Vulkan tới hết process (an toàn, không signal giá trị cũ, nhưng không tự phục hồi).
  - Chỉ chạy thử trên lavapipe. Chưa thử GPU thật, encoder Vulkan, `hwmap` từ CUDA/VAAPI, và Windows (build được, chưa có runner Vulkan).
  - Effect mở trên device mặc định ở `init` (cần biết pad và format trước khi negotiate) rồi biên dịch lại trên device của FFmpeg khi configure: lúc khởi động có hai device và biên dịch gói hai lần.
  - Dùng queue 0 của họ queue compute đầu tiên, khoá bằng `lock_queue` (đã deprecated, `FF_API_VULKAN_SYNC_QUEUES`) quanh mỗi lần gọi; khi FFmpeg bỏ API đó thì cần dựa vào `VK_KHR_internally_synchronized_queues`. Hook `vkGetInstanceProcAddr` giả định một Vulkan loader cho cả process.
  - Filter bị tắt (timeline) trên frame Vulkan luôn chuyển frame qua GPU (output có frames context riêng), không đưa tham chiếu như đường phần mềm. Input chưa bắt đầu là frame đen đục (đường phần mềm: đen trong suốt).
  - Build Docker đầy đủ (`build.sh`) chưa bật Vulkan: image build chưa có Vulkan-Headers ≥ 1.3.277.
- **Vị trí**: [crates/gpufx-core/src/vulkan.rs](../crates/gpufx-core/src/vulkan.rs), [crates/gpufx-core/src/convert.rs](../crates/gpufx-core/src/convert.rs), [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`config_vulkan`, `process_vulkan`), [docker/build-in-container.sh](../docker/build-in-container.sh).
- **Vì sao**: phạm vi B-Vulkan là đường zero-copy chạy đúng với `hwupload`/`hwdownload`; phần còn lại cần GPU thật hoặc thay đổi lớn (view multiplane, cache bind group).
- **Ngày ghi**: 2026-10-12

### B-D3D12 / B-D3D11: các giới hạn còn lại
- **Vấn đề**:
  - CI không kiểm được: runner hosted (chỉ có WARP) không tạo được device d3d12va (-22) / d3d11va (887a0004 DXGI_ERROR_UNSUPPORTED) ngay trong FFmpeg, nên test báo skip kể cả với `REQUIRE_D3D=1`. Mới chạy trên một GPU thật (NVIDIA RTX 4060 Laptop, 2026-10-14, đạt hết); chưa thử AMD/Intel, chưa thử decoder (`-hwaccel d3d12va`/`d3d11va`).
  - D3D11: wgpu giữ lần nạp `d3d12.dll` duy nhất (FFmpeg không nạp nó cho d3d11va), nên `from_d3d11` ghim DLL tới hết process. Gỡ được khi wgpu nhả object D3D12 đúng thứ tự.
  - Dựa vào việc D3D12 trả cùng một device cho cùng adapter trong một process; với Agility SDK hoặc runtime D3D12 khác thì bị từ chối (có thông báo). wgpu-hal có `device_from_raw` cho DX12 thì nên chuyển sang.
  - D3D12: mỗi lần gọi chờ CPU lần submit trước, vì upload D3D12 của FFmpeg ghi vào frame mà không chờ fence của nó (an toàn nhưng mất pipelining một frame).
  - Texture array (decoder), frame lớn hơn kích thước, output không UAV: tốn một lần copy GPU (một frame VRAM mỗi pad). D3D11 input không share được (hwupload, decoder): một lần copy trên immediate context. `GpuFrame` nhận view theo layer thì bỏ được copy của texture array D3D12.
  - Qua FFmpeg chỉ có nv12, p010le (libgpufx còn nhận rgba, rgba64le). BGRA (d3d11va) cần đảo kênh; p016/y210/AYUV... chưa có trong `PixelFormat`.
  - D3D11: cache texture đã mở giữ tối đa 64 tham chiếu tới texture pool của FFmpeg cho tới khi effect bị giải phóng (VRAM của pool sống lâu hơn nếu pool bị huỷ sớm, ví dụ khi reinit).
  - Một submission D3D12 thất bại làm device chia sẻ ngừng dùng (giống Vulkan), chưa có cách phục hồi.
- **Vị trí**: [crates/gpufx-core/src/d3d12.rs](../crates/gpufx-core/src/d3d12.rs), [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`config_d3d`, `process_d3d12`, `process_d3d11`), [scripts/test-bundle.sh](../scripts/test-bundle.sh), [scripts/build-prebuilt.sh](../scripts/build-prebuilt.sh).
- **Vì sao**: cần chạy thử trên GPU AMD/Intel và với decoder D3D.
- **Ngày ghi**: 2026-10-12

### Frame Vulkan: `vk_store` đặt access SHADER_READ|WRITE gây cảnh báo validation
- **Vấn đề**: sau gpufx, `hwdownload` dùng `vkf->access` làm srcAccess trên queue transfer, validation báo `VUID-VkImageMemoryBarrier2-srcAccessMask-03909/07454`. Không gây mất device; việc đồng bộ đã đi qua timeline semaphore nên có thể đặt `VK_ACCESS_2_NONE`.
- **Vị trí**: [ffmpeg/vf_gpufx.c:916](../ffmpeg/vf_gpufx.c#L916).
- **Vì sao**: để chạy sạch dưới validation layer; cần build lại avfilter và chạy với layer để kiểm.
- **Ngày ghi**: 2026-10-13

### Test `exprs` tràn stack ở bản debug trên Windows
- **Vấn đề**: `expressions_are_compiled_into_wgsl_and_glsl` báo `has overflowed its stack` khi `cargo test` (debug) trên Windows có GPU, ở nhánh GLSL. Chạy với `RUST_MIN_STACK=16777216` thì xanh.
- **Vị trí**: [crates/gpufx-core/tests/exprs.rs](../crates/gpufx-core/tests/exprs.rs); có thể do frontend GLSL của naga đệ quy sâu ở bản debug.
- **Vì sao**: `.cargo/config.toml` đã đặt `RUST_MIN_STACK` nên `cargo test` xanh, nhưng thread của filter FFmpeg cũng có stack giới hạn; còn phải biết bản release có an toàn không, nếu không thì chạy phần biên dịch trên thread stack lớn.
- **Ngày ghi**: 2026-10-13

### Frame Vulkan: bắt buộc họ queue có graphics, chưa có test cho nhánh từ chối
- **Vấn đề**: gpufx thuần compute nhưng wgpu ghi render pass và barrier đồ hoạ, nên phải chạy trên họ queue có graphics; không chạy song song được trên họ compute riêng (vd cạnh encoder của FFmpeg). Nhánh `from_vulkan` từ chối họ không có graphics chỉ được kiểm bằng tay (ffmpeg cũ chọn họ 2 trên RTX 4060), chưa có test tự động vì cần GPU thật.
- **Vị trí**: [crates/gpufx-core/src/vulkan.rs](../crates/gpufx-core/src/vulkan.rs) (`GpuContext::from_vulkan`), [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`config_vulkan`).
- **Vì sao**: theo dõi wgpu hỗ trợ queue chỉ có compute; hoặc để libgpufx tự chọn họ từ danh sách thay vì caller.
- **Ngày ghi**: 2026-10-13

### Shader YUV tuỳ chọn cho transition (chọn shader theo tình huống)
- **Vấn đề**: mọi hiệu ứng chạy trên RGBA nên mỗi `gpufx` đổi NV12 → RGBA → NV12 và giữ texture RGBA trung gian. Transition trộn/chọn pixel (crossfade, dissolve, wipe, slide, circle, clock, push…) làm đúng được thẳng trên plane Y và UV vì `lerp` giao hoán với phép đổi YUV ↔ RGB (affine).
- **Thiết kế đề xuất**: manifest khai báo `variants.yuv` (tuỳ chọn) với helper `gpufx_read_y/uv`, `gpufx_write_y/uv`; engine chọn bản YUV khi input và output là NV12/yuv420p và hiệu ứng đứng một mình hoặc mọi hiệu ứng nối nhau đều có bản YUV, ngược lại dùng RGBA; option `variant=auto|rgba|yuv`; CI so pixel hai bản (lệch ≤ 1–2); tham số màu (`#rrggbb`) đổi sang YUV; định dạng khác (P010, 444) quay về RGBA.
- **Vị trí**: [crates/gpufx-core/src/convert.rs](../crates/gpufx-core/src/convert.rs), [crates/gpufx-core/src/runtime.rs](../crates/gpufx-core/src/runtime.rs), manifest ([docs/EFFECT_FORMAT-vi.md](EFFECT_FORMAT-vi.md)), gói transition trong `examples/effects`.
- **Vì sao**: bỏ pass đổi định dạng và texture RGBA, giảm dữ liệu đọc/ghi khoảng 2,7 lần cho chuỗi chỉ có transition (chưa đo).
- **Ngày ghi**: 2026-10-13

### Pool texture dùng chung: các giới hạn còn lại
- **Vấn đề**:
  - (1) Graph còn sống nhưng ngừng chạy (hoặc vừa đổi kích thước) vẫn giữ texture trong bind group/`InputSlot`/mip chain. Trim bỏ entry khỏi pool nhưng VRAM chưa được giải phóng, và `pool_stats` báo thấp hơn thực tế.
  - (2) Ở `vulkan.rs`/`d3d12.rs`, các đường lỗi nằm giữa `encode_gpu` và `release_frame` giữ lease tới lần encode sau.
  - (3) Trim chỉ chạy khi có `give_back`; khi mọi graph cùng dừng thì phần rảnh giữ mãi. Ngưỡng `IDLE_FRAMES × số user` lâu với nhiều graph.
  - (4) Texture tạm của D3D12 chưa vào pool. Nếu `read_outputs` panic thì buffer readback giữ `borrowed` mãi (rò bộ nhớ, không dùng sai).
  - (6) Effect mở trên device noop chỉ có format mặc định của WebGPU: package cần format riêng của adapter bị từ chối lúc open dù GPU thật chạy được ([crates/gpufx-core/src/runtime.rs](../crates/gpufx-core/src/runtime.rs) `GpuContext::noop`). Hướng gọn hơn: chỉ kiểm WGSL bằng naga lúc open, dựng graph một lần khi có device.
  - (5) Pool frame đầu ra (`VkImage`) FFmpeg cấp riêng cho mỗi filter chiếm phần chênh còn lại: 8 filter riêng 322 MB so với 260 MB của graph; với `out_format=rgba` là 442 MB. Pool trước `crossfade` lên tới 10 frame.
- **Vị trí**: [crates/gpufx-core/src/pool.rs](../crates/gpufx-core/src/pool.rs) (`give_back`), [crates/gpufx-core/src/graph.rs](../crates/gpufx-core/src/graph.rs) (`acquire`, `FrameIo`), [crates/gpufx-core/src/vulkan.rs](../crates/gpufx-core/src/vulkan.rs), [crates/gpufx-core/src/d3d12.rs](../crates/gpufx-core/src/d3d12.rs), [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`initial_pool_size` của frames ctx đầu ra).
- **Vì sao**: (1) nên để pool sở hữu bind group theo id lease, hoặc đánh dấu id bị trim để graph bỏ binding; (5) giới hạn pool đầu ra sẽ đưa 8 filter riêng về gần mức của graph.
- **Ngày ghi**: 2026-10-13

### `gpufx_upload`/`gpufx_download`: các giới hạn còn lại
- **Vấn đề**: (1) đổi kích thước frame giữa chừng thì trả EINVAL (cần chờ các slot, dựng lại vùng copy và buffer, download phải xả frame đang chờ trước); (2) libavfilter build với Vulkan-Headers khác bản của libavutil dựng sẵn nên pool không lấy được queue (cờ internally synchronized queues), filter lấy lại queue bằng `queue_flags` của device — sinh VUID-VkDeviceQueueInfo2-flags-06225 một lần; (3) `out_format` dùng một format cho mọi output, chưa nhận danh sách theo từng output; (4) chưa thử `gpufx_download` với frame của `-hwaccel vulkan`; (5) chỉ có cho Vulkan, chưa có cho D3D.
- **Vị trí**: [ffmpeg/vf_gpufx_transfer.c](../ffmpeg/vf_gpufx_transfer.c) (`check_size`, khối lấy lại queue sau `ff_vk_exec_pool_init`), [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`out_format`), [scripts/build-prebuilt.sh](../scripts/build-prebuilt.sh) (tag Vulkan-Headers).
- **Vì sao**: (1) nguồn đổi độ phân giải làm dừng cả graph; (2) nên khớp phiên bản header với libavutil thay vì vá lúc chạy.
- **Ngày ghi**: 2026-10-13

### [Vừa] Frame VideoToolbox (macOS): chưa chạy trên máy Mac, còn các giới hạn
- **Vấn đề**: đường frame VideoToolbox của `gpufx` (IOSurface → texture Metal, đọc/ghi tại chỗ) mới chỉ `cargo check`/`clippy` cho `aarch64-apple-darwin` từ Windows và biên dịch thử `vf_gpufx.c` với `CONFIG_VIDEOTOOLBOX=1`; chưa chạy trên máy Mac. Job CI `ffmpeg-macos` (build FFmpeg từ submodule rồi chạy `test-bundle.sh` với `REQUIRE_VT=1`) chưa chạy lần nào; runner hosted có thể không có adapter Metal (test bị bỏ qua kèm cảnh báo). Các điểm chưa kiểm chứng: (1) `newTextureWithDescriptor:iosurface:plane:` với texture nhỏ hơn plane IOSurface (surface có padding); Mac Intel (không unified memory) bị từ chối, chưa có đường blit `synchronizeResource`; (2) ghi storage vào texture IOSurface R8/RG8 của wgpu Metal. Giới hạn còn lại: (3) output p010le cần storage R16/RG16, GPU không có (không phải Apple) thì báo lỗi, chưa có đường dự phòng (vd ghi vào texture riêng rồi copy, hoặc chuyển về nv12); (4) chỉ nhận nv12/p010le: input CPU không phải 4:2:0 (yuv422p, RGB...) không upload được, chưa nhận frame BGRA/RGBA của VideoToolbox; (5) không có fence nên mỗi event chờ CPU tới khi GPU xong (không chồng việc giữa các frame); (6) attachment màu (`CVBufferSetAttachment`) của `CVPixelBuffer` output không được cập nhật theo màu filter ghi ra.
- **Vị trí**: [crates/gpufx-core/src/videotoolbox.rs](../crates/gpufx-core/src/videotoolbox.rs) (`wrap`, `process_videotoolbox`), [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`sw_format_ok`, `process_videotoolbox`), [scripts/test-bundle.sh](../scripts/test-bundle.sh) (mục "VideoToolbox frames"), job `ffmpeg-macos` trong [.github/workflows/ci.yml](../.github/workflows/ci.yml).
- **Vì sao nên làm**: người dùng macOS chỉ còn đường này để dùng filter; cần một lần chạy thật (máy Mac hoặc runner có Metal) để xác nhận, rồi mới gỡ dòng "chưa kiểm" trong README.
- **Ngày ghi**: 2026-10-14

### [Vừa] Đọc/ghi frame Vulkan tại chỗ: wrapper giữ qua frame, pass cuối ghi thiếu pixel
- **Vấn đề**:
  - Wrapper wgpu của image FFmpeg (và view, bind group dựng từ chúng) được cache theo `VkImage` (16 frame mỗi pad, `ImportCache` trong `vulkan.rs`, `Lru` trong `InputSlot`, `GpuOutputSlot`, `Effect::rebind`), nên được giữ qua frame tới khi bị đẩy khỏi cache hoặc graph bị huỷ. Filter giữ ref các frames context Vulkan của input/output (`hold_vk_frames` trong `vf_gpufx.c`) tới sau `gpufx_effect_free`, nên image không bị giải phóng trước wrapper. Còn hở: frames context bị thay giữa chừng (cấu hình lại link) thì ref cũ vẫn giữ tới khi filter bị huỷ (tốn VRAM, không sai); dùng `process_vulkan` từ Rust mà không giữ image như vậy thì wrapper có thể sống lâu hơn image. Đường D3D12/D3D11 chưa có cache, vẫn giữ wrapper của frame cuối tới frame sau.
  - Output ghi tại chỗ được rào layout từ `UNDEFINED` (bỏ nội dung cũ) khi chưa ở `GENERAL`: pass cuối mà không ghi đủ mọi pixel thì phần thiếu là nội dung cũ của frame trong pool FFmpeg (trước đây là nội dung cũ của texture trong pool gpufx).
  - Một frame `split` nằm trên hai pad có hai wrapper wgpu cho cùng `VkImage` (cache theo pad), mỗi wrapper wgpu theo dõi trạng thái riêng: trong một submit hai wrapper có thể chuyển image sang hai layout khác nhau. Có từ trước, cache làm nó kéo dài qua frame; nên khoá cache theo image cho mọi pad (`vulkan.rs` `ImportKey`).
  - Cách làm hiện tại rải điều kiện qua ba chỗ phải khớp nhau (`prepare`/`direct_outputs`, `acquire` với stand-in, `record_gpu` bind lại).
- **Vị trí**: [crates/gpufx-core/src/graph.rs](../crates/gpufx-core/src/graph.rs) (`direct_outputs`, `acquire`, `record_gpu`), [crates/gpufx-core/src/runtime.rs](../crates/gpufx-core/src/runtime.rs) (`Effect::rebind`), [crates/gpufx-core/src/vulkan.rs](../crates/gpufx-core/src/vulkan.rs) (`ImportCache`), [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`hold_vk_frames`).
- **Vì sao nên làm**: dễ bảo trì hơn nếu gom ba chỗ điều kiện về một; cache import Vulkan và rào layout thô mỗi frame chưa có test với `VkImage` thật (test Rust dùng texture wgpu thường, chỉ kiểm qua bundle FFmpeg).
- **Ngày ghi**: 2026-10-13

### [Thấp] Pass chuyển đổi YUV vẫn chậm gấp ~3 lần một pass hiệu ứng
- **Vấn đề**: sau đợt tối ưu (tile chroma trong workgroup, một pass ghi mọi plane, chọn kênh bằng `select`), với frame nv12 1080p trên RTX 4060 copy-in còn ~0.087 ms và copy-out ~0.105 ms, trong khi một pass vignette đọc/ghi RGBA chỉ ~0.033 ms. Thử thêm: mỗi invocation một khối 2x2 với 3x3 mẫu chroma trong thanh ghi (chậm hơn, 0.100 ms), workgroup 16x16 cho pass ra (không đổi), nạp luma trước barrier (chậm hơn). Phần còn lại của copy-out là nạp tile pixel và đổi sang YUV (~0.07 ms khi bỏ bộ lọc chroma). Đường frame từ CPU (`convert_in_plain.wgsl`, `convert_out_buffer.wgsl`) chưa đổi, vẫn đọc chroma từng pixel và chỉ số vector lúc chạy.
- **Vị trí**: [crates/gpufx-core/src/convert_in_tiled.wgsl](../crates/gpufx-core/src/convert_in_tiled.wgsl), [crates/gpufx-core/src/convert_out_fused.wgsl](../crates/gpufx-core/src/convert_out_fused.wgsl), [crates/gpufx-core/src/convert_out_buffer.wgsl](../crates/gpufx-core/src/convert_out_buffer.wgsl).
- **Vì sao nên làm**: với 8 filter riêng, copy vẫn chiếm phần lớn thời gian GPU; đường CPU có thể dùng chung các pass mới (byte ra giống hệt) nếu được duyệt đổi.
- **Ngày ghi**: 2026-10-13

### [Thấp] Chuỗi nhiều filter `gpufx` riêng vẫn tốn VRAM hơn một `graph=` (pool frame đầu ra)
- **Vấn đề**: 8 filter riêng với `out_format=rgba` qua `gpufx_upload`/`gpufx_download` dùng 421 MB VRAM, một `graph=` dùng 256 MB (NV12: 320 MB). Phần dôi gần như là frame đầu ra đang chờ ở các chỗ nối giữa filter: mỗi filter có pool `VkImage` riêng, mỗi pool giữ mức đỉnh của nó (trước `crossfade` lên 5–10 frame vì framesync chờ ghép cặp hai nhánh). Frame RGBA 1080p nặng 8,3 MB so với 3,1 MB của NV12.
- **Vị trí**: [ffmpeg/vf_gpufx.c](../ffmpeg/vf_gpufx.c) (`config_vulkan_output`, tạo frames context đầu ra), [ffmpeg/vf_gpufx_transfer.c](../ffmpeg/vf_gpufx_transfer.c) (`depth` của `gpufx_upload`).
- **Hướng đã bàn, chưa duyệt**:
  - Dùng chung pool frame giữa các filter `gpufx` cùng device, phân nhóm theo kích thước/format/usage; không khớp thì tạo pool riêng như hiện nay. VRAM khi đó bằng số frame thật sự đang sống thay vì tổng mức đỉnh từng pool. Không hại hiệu suất.
  - Hướng dẫn cho filter ngay trước filter nhiều đầu vào xuất NV12; thử giảm `depth` của `gpufx_upload`.
  - Không giới hạn kích thước pool đầu ra: frame sẽ phải chờ hoặc báo lỗi, hại hiệu suất.
- **Vì sao nên làm**: chuỗi effect/transition thường giữ nguyên kích thước nên pool dùng chung áp dụng được cho phần lớn trường hợp; ước tính giảm vài chục tới hơn 100 MB với rgba (chưa đo).
- **Ngày ghi**: 2026-10-13

### [Thấp] Filter `gpufx` upload lại input CPU ở mọi event

- Vấn đề: input là frame CPU bị chuyển đổi rồi upload lại ở mỗi event của framesync, kể cả khi input phụ chậm hơn chỉ lặp lại đúng frame cũ (vd ảnh tĩnh). Upload chạy đồng bộ, nên mỗi event tốn một lần chép cho mỗi input.
- Vị trí: `ffmpeg/vf_gpufx.c`, `upload_input` (~1436) và lời gọi trong vòng event (~1618).
- Vì sao nên làm: cache theo danh tính frame (buffer + pts) sẽ bỏ được các lần chép thừa.
- Ngày ghi: 2026-10-14 (review đợt chỉ xuất frame GPU).

### [Thấp] `passthrough=off`: mỗi gpufx tắt copy qua RGBA làm chroma giảm dần

Vấn đề: với `passthrough=off` (hoặc khi không gắn nhãn được), gpufx bị tắt copy frame trên GPU qua một vòng YUV→RGBA→YUV. Chuỗi 5 gpufx tắt liên tiếp làm chroma giảm còn khoảng 37 dB so với bản gắn nhãn, và chậm hơn 2,2 lần (bài đo nối 6 clip trong `docs/BENCHMARK-vi.md`). Vị trí: `passthrough_frame` / nhánh copy trong `ffmpeg/vf_gpufx.c`. Nên làm: khi input và output cùng `sw_format` thì copy thẳng từng plane (không đổi màu). Ghi ngày 2026-10-15.

### [Thấp] Frame YUV không có tag màu: gpufx đoán matrix/range khác FFmpeg

Vấn đề: đưa file yuv thô không gắn `colorspace`/`range` qua `gpufx_upload` → `gpufx_download` chỉ đạt khoảng 25 dB so với nguồn; gắn `setparams=range=tv:colorspace=bt709` thì lên khoảng 42 dB (bài đo "Filter nặng hơn" trong `docs/BENCHMARK-vi.md`). Vị trí: chỗ chọn matrix/range khi frame có `AVCOL_SPC_UNSPECIFIED`/`AVCOL_RANGE_UNSPECIFIED` trong `ffmpeg/vf_gpufx.c` và phần chuyển YUV của gpufx-core. Nên làm: khi thiếu tag thì mặc định giống swscale (BT.601 cho SD, BT.709 cho HD, limited range), và thêm test. Ghi ngày 2026-10-15.
