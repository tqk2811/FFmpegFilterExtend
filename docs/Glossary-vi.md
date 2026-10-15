# Thuật ngữ

## AVHWDeviceContext

Device context của FFmpeg (`libavutil/hwcontext.h`): bọc một GPU đã mở (`VkInstance`/`VkDevice`/queue với Vulkan, `ID3D11Device`/`ID3D12Device` với D3D). Cả chuỗi filter thường dùng chung một device context, gpufx chạy shader trên đúng `VkDevice` của FFmpeg.

## AVHWFramesContext

Frames context của FFmpeg (`libavutil/hwcontext.h`): mô tả và cấp phát một pool frame GPU trên một device context. Mỗi link chở frame GPU gắn một frames context (`hw_frames_ctx`), và mỗi frame GPU cũng trỏ về frames context đã cấp nó. Gồm mô tả chung (`format`, `sw_format`, `width`, `height`, `pool`) và phần riêng từng API ở `hwctx` (Vulkan: `AVVulkanFramesContext` với `tiling`, `usage`, `flags`, `img_flags`, `format[]`, `lock_frame`/`unlock_frame`).

## AVVkFrame

Một frame Vulkan của FFmpeg (`libavutil/hwcontext_vulkan.h`), nằm ở `AVFrame.data[0]`: các `VkImage` + `VkDeviceMemory` của từng plane, kèm trạng thái đồng bộ đi theo image (`layout`, `access`, timeline `sem` + `sem_value`).
