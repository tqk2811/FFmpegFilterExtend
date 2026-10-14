# Vulkan Intel trên Windows: lỗi host image copy (FFmpeg 9)

[English](INTEL_VULKAN.md) · [README](../README-vi.md)

Tóm tắt: trên GPU Intel chạy Windows, upload bằng `gpufx_upload` và readback bằng `gpufx_download` (hoặc
`hwdownload` thường ngay sau một `gpufx`) thay cho `hwupload` / `hwdownload` quanh frame do FFmpeg tự tạo.
Trên driver đó `gpufx` từ chối frame của `hwupload` kèm thông báo chỉ cách sửa.

## Nguyên nhân

FFmpeg 9 bật `VK_EXT_host_image_copy` khi device có extension này và có resizable BAR
(`libavutil/hwcontext_vulkan.c`, danh sách extension và đoạn kiểm ReBAR lúc dựng device). Khi đó mọi frames
context Vulkan đều được thêm `VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT` (`vulkan_frames_init`, trừ NVIDIA và
MoltenVK), bất kể usage người gọi đặt trước, và `av_hwframe_transfer_data()` (`hwupload`, `hwdownload`) copy bằng
`vkCopyMemoryToImageEXT` / `vkCopyImageToMemoryEXT` thay vì copy trên GPU qua staging buffer.
FFmpeg 8.0.1 không làm vậy.

Driver Intel Windows (đã thử: UHD Graphics RaptorLake-S, driver 101.7082) làm sai hai trường hợp:

- **A. Cấp phát hỏng.** Ảnh tiling optimal có usage host-transfer và chỉ một plane (`rgba`, `bgra`, và mọi plane
  khi `disable_multiplane=1`) làm `vkAllocateMemory` trả `VK_ERROR_OUT_OF_HOST_MEMORY`. Triệu chứng: `hwupload`
  dừng với `Failed to allocate memory: VK_ERROR_OUT_OF_HOST_MEMORY` / `vulkan_pool_alloc failed with error -12`.
  Cùng ảnh đó với tiling linear thì cấp phát được.
- **B. Hỏng ảnh không báo lỗi.** Host copy vào và ra ảnh multi-planar (`nv12`, `yuv420p` là một `VkImage`) ghi dữ
  liệu chroma vào plane 0. Chỉ `hwupload,hwdownload` không có gì ở giữa cũng trả về ảnh khác: khoảng một phần tư
  số byte luma sai, cộng nửa số byte UV của nv12 hoặc toàn bộ plane U của yuv420p (chứa dữ liệu V). Không có thông báo lỗi nào.

Cùng các lệnh đó cho kết quả trùng từng bit trên NVIDIA RTX 4060 (FFmpeg tắt host copy trên NVIDIA) và với
FFmpeg 8.0.1 trên GPU Intel. `gpufx_upload` / `gpufx_download` ghi lệnh copy trên GPU qua buffer riêng và trùng
từng bit trên GPU Intel.

Bằng chứng (FFmpeg `03d9533176`, nv12 / yuv420p 320x180, Intel = `vk:1`):

| Option của device | Vòng nv12 | Vòng yuv420p | rgba |
| --- | --- | --- | --- |
| không có | khác (B) | khác (B) | cấp phát hỏng (A) |
| `disable_multiplane=1` | cấp phát hỏng (A) | cấp phát hỏng (A) | cấp phát hỏng (A) |
| `linear_images=1` | khác (B) | khác (B) | chạy |
| `disable_multiplane=1,linear_images=1` | trùng | trùng | chạy |

## gpufx xử lý thế nào

- Mọi frames context Vulkan do `gpufx`, `gpufx_upload` và `gpufx_download` tạo (frame output, frame cho input
  CPU, frame trống cho input bắt đầu muộn, pool của upload) bỏ `VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT` ngay sau
  `av_hwframe_ctx_init()` (`gpufx_hwframe_ctx_init` trong `ffmpeg/vf_gpufx_vk.h`). FFmpeg thêm cờ này dù usage đã
  đặt trước, nhưng ảnh chỉ được tạo ở frame đầu tiên nên không bao giờ mang cờ đó. Bộ nhớ của chúng cấp phát được
  (không dính A) và `hwdownload` các frame này dùng copy qua buffer của FFmpeg (không dính B). Không sửa mã nguồn
  FFmpeg.
- Input của `gpufx` có frame do FFmpeg tạo với usage host-transfer trên driver Intel Windows, tiling optimal hoặc
  multi-planar (tức `hwupload` cho ra frame hỏng hoặc không cấp phát được), bị từ chối lúc dựng graph. Thông báo
  lỗi nêu tên input và các cách sửa bên dưới. Frame của decoder không bị ảnh hưởng (GPU ghi chúng), và frame
  linear một plane (`disable_multiplane=1,linear_images=1`) được nhận.

## Dùng gpufx_upload / gpufx_download

```sh
ffmpeg -init_hw_device vulkan=vk:1,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx=effect=vignette.zip,gpufx_download,format=nv12" out.mp4
```

Input CPU đưa thẳng vào `gpufx` được `gpufx` tự upload nên cũng không sao, và `hwdownload` sau `gpufx` đọc đúng
frame của `gpufx`. Chỉ frame do FFmpeg cấp phát (`hwupload`, `hwdownload` frame của `hwupload`, output riêng của
các filter `*_vulkan`) mới đi qua host copy bị lỗi.

Nên dùng cách này trên mọi GPU, không riêng Intel: trên NVIDIA `gpufx_upload` / `gpufx_download` chạy copy nối
đuôi và nhanh hơn `hwupload` / `hwdownload` (xem [BENCHMARK-vi.md](BENCHMARK-vi.md)).

## FFmpeg thuần: disable_multiplane=1,linear_images=1

Graph buộc phải dùng `hwupload` / `hwdownload` (filter Vulkan khác, không có `gpufx`) thì mở device với cả hai
option:

```sh
ffmpeg -init_hw_device vulkan=vk:1,disable_multiplane=1,linear_images=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=effect=vignette.zip,hwdownload,format=nv12" out.mp4
```

Cần cả hai:

- chỉ `disable_multiplane=1`: mỗi plane một ảnh một plane, nhưng vẫn tiling optimal, nên dính lỗi A, cấp phát hỏng;
- chỉ `linear_images=1`: ảnh linear nhưng multi-planar, nên dính lỗi B, chroma vẫn hỏng;
- có cả hai: ảnh linear và một plane, các vòng thử ở bảng trên trùng từng bit.

Cái giá: GPU đọc (sample) và ghi ảnh linear chậm hơn ảnh optimal (bộ nhớ xếp theo tile mới là kiểu texture unit
được thiết kế cho), và mỗi plane là một ảnh riêng. `gpufx` nhận các frame này.
Toàn bộ bộ test gpufx chạy qua trên GPU Intel với hai option này và `hwupload` (`VK_DEVICE_OPTS=disable_multiplane=1,linear_images=1 VK_ADAPTER=1 sh scripts/test-bundle.sh ...`: 157 ok, 2026-10-14).

Một lối khác trên Windows là frame D3D11 (`-init_hw_device d3d11va=dx -filter_hw_device dx`), `gpufx` cũng đọc
và ghi được.

## Tình trạng phía upstream

Bản báo lỗi cho FFmpeg (bật host image copy trên driver làm sai) và cho Intel (lỗi A và B) đã soạn kèm cách tái
hiện, chưa gửi. Khi driver hoặc FFmpeg đã sửa thì có thể bỏ lệnh từ chối trong `gpufx` và phần né trong test
(mục backlog trong [Backlog-vi.md](Backlog-vi.md)).

## Cách kiểm lại

```sh
# in.yuv lấy từ một FFmpeg bất kỳ có lavfi (bundle không có filter nguồn)
ffmpeg -v error -f lavfi -i testsrc2=s=320x180 -frames:v 1 -pix_fmt nv12 -f rawvideo in.yuv
ffmpeg -v error -init_hw_device vulkan=vk:1 -filter_hw_device vk -f rawvideo -pix_fmt nv12 -s 320x180 -i in.yuv \
  -vf "hwupload,hwdownload,format=nv12" -f rawvideo out.yuv
md5sum in.yuv out.yuv  # B: phải trùng
# A: cấp phát rgba (driver dính lỗi báo VK_ERROR_OUT_OF_HOST_MEMORY)
ffmpeg -v error -init_hw_device vulkan=vk:1 -filter_hw_device vk -f rawvideo -pix_fmt nv12 -s 320x180 -i in.yuv \
  -vf "format=rgba,hwupload,hwdownload,format=rgba" -f null -
# Device có dùng host image copy không, driver nào?
ffmpeg -v verbose -init_hw_device vulkan=vk:1 2>&1 | grep -E "selected|host_image_copy"
# Bộ test gpufx trên device đó (tự chuyển sang gpufx_upload và kiểm lệnh từ chối)
VK_ADAPTER=1 DX_ADAPTER=1 REQUIRE_D3D=1 sh scripts/test-bundle.sh dist/win64
```
