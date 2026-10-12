# Kế hoạch GPU chính

Kế hoạch đang làm. Xong bước nào thì đánh dấu; xong cả kế hoạch thì xoá file này (thiết kế lâu dài
nằm ở [DESIGN-vi.md](DESIGN-vi.md) mục 6).

Quy tắc chung: **tiết kiệm VRAM tối đa**, không nhân bản texture (xem "Ngân sách VRAM" trong
DESIGN-vi.md mục 6).

| Bước | Nội dung | Trạng thái |
|------|----------|------------|
| A2 | Chuỗi `effect='a.zip\|b.zip'`, C API v3, thời gian chính xác, `pixel_aspect` | Xong |
| B-chung (P1) | YUV (NV12, P010, yuv420p) ↔ RGBA trên GPU; `rgba16float` chỉ khi cần; pool texture, dùng lại buffer staging | Đang làm |
| Đồ thị GPU | `gpufx=graph='...'`: `EffectChain` thành DAG, nhiều input/output pad, `split` không copy, texture trả pool sau lần đọc cuối | Chưa |
| B-Vulkan (P3) | Zero-copy `AV_PIX_FMT_VULKAN`: device wgpu từ `AVVulkanDeviceContext`, nhận/trả `VkImage`, semaphore của `AVVKFrame` | Chưa |
| B-D3D12 (P5) | `AV_PIX_FMT_D3D12` vào backend DX12 của wgpu; chạy thử trên WARP | Chưa |
| B-D3D11 (P5) | D3D11 qua shared NT handle sang DX12 | Chưa |

## B-chung: phạm vi
- Plane YUV upload thành texture riêng, pass chuyển đổi dựng sẵn trước/sau chuỗi; ma trận 601/709/2020,
  limited/full range lấy từ `AVFrame`. Format khác vẫn qua `swscale`.
- Texture trung gian `rgba16float` chỉ khi input/output trên 8 bit.
- C API phiên bản mới cho frame nhiều plane, dùng trong `vf_gpufx.c`.

## Đồ thị GPU: phạm vi
- Cú pháp nhãn giống filter graph của FFmpeg; tham số theo nhãn nút; `sendcmd` vẫn dùng được.
- Kiểm tra lúc configure: vòng lặp, nhãn thừa/thiếu, quy tắc kích thước/format; tính trước số
  texture sống đồng thời tối đa.
- `effect='a|b'` là đồ thị thẳng, giữ tương thích.

## B-Vulkan: phạm vi
- Test `hwupload → gpufx → split → gpufx… → hwdownload`, gpufx nhiều input đều là frame GPU, trộn
  frame CPU/GPU báo lỗi rõ ràng.
