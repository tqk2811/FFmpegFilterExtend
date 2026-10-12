# Kế hoạch GPU chính

Kế hoạch đang làm. Xong bước nào thì đánh dấu; xong cả kế hoạch thì xoá file này (thiết kế lâu dài
nằm ở [DESIGN-vi.md](DESIGN-vi.md) mục 6).

Quy tắc chung: **tiết kiệm VRAM tối đa**, không nhân bản texture (xem "Ngân sách VRAM" trong
DESIGN-vi.md mục 6).

| Bước | Nội dung | Trạng thái |
|------|----------|------------|
| A2 | Chuỗi `effect='a.zip\|b.zip'`, C API v3, thời gian chính xác, `pixel_aspect` | Xong |
| B-chung (P1) | YUV (NV12, P010, yuv420p) ↔ RGBA trên GPU; `rgba16float` chỉ khi cần; pool texture, dùng lại buffer staging | Xong (C API v4) |
| Đồ thị GPU | `gpufx=graph='...'`: `EffectChain` thành DAG, nhiều input/output pad, `split` không copy, texture trả pool sau lần đọc cuối | Xong (C API v5) |
| B-Vulkan (P3) | Zero-copy `AV_PIX_FMT_VULKAN`: device wgpu từ `AVVulkanDeviceContext`, nhận/trả `VkImage`, semaphore của `AVVKFrame` | Chưa |
| B-D3D12 (P5) | `AV_PIX_FMT_D3D12` vào backend DX12 của wgpu; chạy thử trên WARP | Chưa |
| B-D3D11 (P5) | D3D11 qua shared NT handle sang DX12 | Chưa |
| Cache shader | Lưu shader/pipeline đã biên dịch ra đĩa, thư mục lấy từ biến môi trường `GPUFX_SHADER_CACHE` | Xong bước 1 (Vulkan `PipelineCache`); DXIL D3D12 và `pack --precompile` trong Backlog |

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

## Cache shader: phạm vi
- **Vì sao**: biên dịch tốn thời gian mỗi lần mở gói, nhất là D3D12 (đo trên CI: FXC 50–160 s cho shader lá
  trên WARP, DXC nhanh hơn nhưng vẫn đáng kể). Cache hiện tại (`Program`) chỉ sống trong một process.
- **Bật**: `GPUFX_SHADER_CACHE=<thư mục>`. Không đặt thì không ghi gì ra đĩa (hành vi như hiện nay).
  Thư mục chưa có thì tạo; không ghi được thì cảnh báo một lần rồi chạy tiếp không cache.
- **Tên file**: hash (SHA-256, hex) của mọi thứ ảnh hưởng tới kết quả: nguồn shader cuối cùng (sau khi
  chèn prelude), ngôn ngữ, entry point, phiên bản gpufx và wgpu, backend, thông tin adapter (vendor,
  device, driver, driver_info). Đổi một trong các thứ đó thì ra file khác; không cần kiểm mtime.
- **Lưu gì** (đã kiểm với mã nguồn wgpu 30.0.1):
  - **Vulkan**: `wgpu::PipelineCache`. Cần xin `Features::PIPELINE_CACHE` trong `request_device`
    (`required_features`, hiện chưa xin); tạo một cache cho mỗi device bằng `create_pipeline_cache`
    (`unsafe`, `fallback: true` để dữ liệu của driver/wgpu khác bị bỏ qua), truyền vào
    `ComputePipelineDescriptor.cache` (hiện là `None`), sau khi tạo pipeline thì `get_data()` (có thể
    `None`) rồi ghi file. `wgpu::util::pipeline_cache_key` chỉ có trên Vulkan; tên file vẫn dùng SHA-256
    ở trên vì chặt hơn.
  - **D3D12, Metal, GL**: wgpu 30 không có cache ra đĩa (`create_pipeline_cache` là stub rỗng; DX12 chỉ
    có cache HLSL trong bộ nhớ, 200 mục; PSO cache để trống). Bước 1 dựa vào cache của driver, ghi rõ là
    giới hạn đã biết.
  - **D3D12 bước 2** (chỗ chậm nhất): tự biên dịch và lưu DXIL. naga → HLSL, gọi `dxcompiler.dll` (đã đi
    kèm bản win64) ra DXIL, lưu file; lần sau nạp bằng `Features::PASSTHROUGH_SHADERS` +
    `create_shader_module_passthrough` (`unsafe`, wgpu không kiểm tra nên chỉ nạp file mình đã ghi và
    khớp hash). Metal tương tự với `metallib` nếu cần. Driver vẫn phải tạo pipeline state.
- **An toàn**: ghi vào file tạm rồi rename (nhiều process cùng ghi không làm hỏng file); file hỏng hoặc
  không khớp thì bỏ qua và ghi lại; file cache là dữ liệu không tin cậy, chỉ đưa qua API có kiểm tra
  của wgpu/driver. Giới hạn tổng dung lượng (xoá file cũ nhất theo thời gian truy cập).
- **Test**: lần mở thứ hai trong process mới đọc được file cache (gpufx tự đếm số file nạp, wgpu không có bộ đếm hit), output giống hệt;
  file hỏng không làm sập; thư mục không ghi được chỉ cảnh báo.
- **Biên dịch sẵn lúc pack** (tuỳ chọn, `gpufx pack --precompile`): gói kèm thư mục `compiled/` với
  bytecode theo từng backend, tên file là hash như trên (không có phần adapter/driver):
  - DXIL cho D3D12: naga → HLSL → DXC (có bản Linux, ký sẵn từ 1.8.2505), không phụ thuộc GPU.
    Đây là chỗ có lợi nhất vì bỏ được bước HLSL → DXIL chậm.
  - SPIR-V cho Vulkan: naga sinh rất nhanh, lợi ít; chỉ thêm nếu đo thấy đáng.
  - Metal: `metallib` cần công cụ Apple (`xcrun metal`), chỉ làm được khi pack trên macOS; nếu không có
    thì bỏ qua, runtime tự biên dịch MSL.
  - Mã máy của GPU (pipeline state, ISA của driver) không thể biên dịch sẵn; phần đó vẫn do cache
    `GPUFX_SHADER_CACHE` ở trên lo.
  - **An toàn**: gói là dữ liệu không tin cậy, còn passthrough shader thì wgpu không kiểm tra, nên
    bytecode lạ có thể làm sập driver. Vì vậy chỉ dùng `compiled/` khi gói đã được ký (`signature`,
    DESIGN mục 7) hoặc người dùng bật `GPUFX_TRUST_PRECOMPILED=1`; ngược lại bỏ qua và biên dịch từ nguồn.
    Gói luôn giữ nguồn shader; bytecode không khớp hash của nguồn hiện tại thì bỏ qua.
- Tài liệu: biến môi trường trong README, DESIGN (cả hai thứ tiếng).
