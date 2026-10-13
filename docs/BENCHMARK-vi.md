# Đo tốc độ

[English](BENCHMARK.md) · [README](../README-vi.md)

Bản build `b1531dc` (gói release win64), đo ngày 2026-10-13.

- **Máy**: Intel Core i9-14900HX, RAM 32 GiB DDR5-5600 (2 × 16 GiB), NVIDIA GeForce RTX 4060 Laptop GPU
  8 GiB VRAM (driver 617.42), Windows 11 Pro.
- **Input**: hai clip H.264, 1920×1080, 23.976 fps, mỗi clip 90 s (2158 frame), decode bằng CPU, ghi ra
  `-f null`. Trên Windows gpufx mặc định chọn Vulkan (`backend=auto`).
- **So với**: FFmpeg 8.0.1 (bản gpl-shared) với filter CPU có sẵn. Chuyển cảnh chạy trong 60 s đầu (`xfade` không
  nhận `duration` quá 60 s); gpufx dùng `progress=clip(t/60,0,1)`.
- Thời gian lấy lần nhanh nhất trong 3 lần. RAM là working set đỉnh; VRAM là đỉnh của counter Windows
  "GPU Process Memory" (dedicated / shared).

**Một hiệu ứng chuyển cảnh**

| Filter | Thời gian | RAM đỉnh | VRAM ded. / shared |
|---|---|---|---|
| Chỉ decode (không filter) | 2.18 s | 309 MB | 0 |
| `xfade` fade (CPU) | 3.49 s | 587 MB | 0 |
| `xfade` wipeleft (CPU) | 3.12 s | – | 0 |
| `xfade` circleopen (CPU) | 8.00 s | 549 MB | 0 |
| `xfade_vulkan` fade (hwupload/hwdownload) | 5.33 s | – | 399 / 80 MB |
| gpufx `crossfade.zip`, Vulkan | 5.19 s | 491 MB | 201 / – |
| gpufx `crossfade.zip`, DX12 | 7.26 s | 546 MB | 173 / 154 MB |
| gpufx `wipe-transition.zip`, Vulkan | 5.22 s | 490 MB | 201 / – |
| gpufx `circle-reveal.zip`, Vulkan | 5.16 s | 488 MB | 202 / – |

**Chuỗi nhiều hiệu ứng**: clip A blur → chỉnh màu → vignette, clip B sepia → sharpen → vignette, crossfade, rồi
sharpen. Phía CPU dùng `gblur`, `eq`, `vignette`, `colorchannelmixer`, `unsharp`, `xfade`.

| Filter | Thời gian | RAM đỉnh | VRAM ded. / shared |
|---|---|---|---|
| Filter CPU | 34.95 s | 655 MB | 0 |
| 8 filter `gpufx` riêng | 29.77 s | 586 MB | 202 / – |
| một `gpufx=graph=...` | **7.05 s** | 491 MB | 202 / – |

**Frame Vulkan và filter truyền frame** (cùng máy, 2026-10-13, khoảng của 3 lần chạy, máy đang chạy desktop bình thường (trình duyệt, Discord, Steam; GPU tải vài %) nên độ lệch rộng; RAM là
working set đỉnh, VRAM là dedicated đỉnh của lần 3). Các dòng gpufx ở hai bảng đầu được đo lại trên bản build này (chưa đo lại VRAM shared); dòng CPU, `xfade_vulkan` và DX12 giữ số của bản build trước. Phần truyền: chỉ clip A, nv12, 90 s.

| Filter | Thời gian | RAM đỉnh | VRAM ded. |
|---|---|---|---|
| Chỉ decode (nv12) | 1.92–2.07 s | 262 MB | 16 MB |
| `hwupload,hwdownload` | 3.63–4.11 s | 280 MB | 26 MB |
| `gpufx_upload,hwdownload` | 3.28–4.09 s | 284 MB | 32 MB |
| `hwupload,gpufx_download` | 2.39–3.07 s | 297 MB | 35 MB |
| `gpufx_upload,gpufx_download` | 2.23–3.07 s | 289 MB | 32 MB |
| Chuỗi, 8 `gpufx` riêng, hwupload/hwdownload | 9.83–13.27 s | 547 MB | 316 MB |
| Chuỗi, 8 `gpufx` riêng, gpufx_upload/download | 8.97–15.51 s | 559 MB | 320 MB |
| Chuỗi, 8 riêng, `out_format=rgba`, hwupload/hwdownload | 9.19–15.23 s | 542 MB | 419 MB |
| Chuỗi, 8 riêng, `out_format=rgba`, gpufx_upload/download | 5.95–8.26 s | 527 MB | 421 MB |
| Chuỗi, một `graph=`, hwupload/hwdownload | 8.88–10.82 s | 509 MB | 253 MB |
| Chuỗi, một `graph=`, gpufx_upload/download | **5.32–6.13 s** | 479 MB | 256 MB |

`gpufx_download` bỏ được phần lớn chi phí readback (`hwdownload` chờ từng lần copy); phía upload
lợi ít vì `hwupload` vốn cũng không chờ.

Nhận xét:

- Frame nằm trong RAM thì mỗi filter `gpufx` tốn khoảng 1.5 ms mỗi frame dù shader làm gì: upload, đổi YUV → RGBA
  trên GPU, readback và chờ GPU. Việc đổi pixel format chạy bằng shader, FFmpeg không chèn filter `scale`. Vì vậy
  một chuyển cảnh nhẹ đứng riêng chậm hơn `xfade` trên CPU mạnh.
- Gom cả chuỗi vào một `gpufx` (`graph=` hoặc `effect='a.zip|b.zip'`): frame chỉ qua bus một lần, thêm hiệu ứng gần
  như không tốn (8 hiệu ứng: 7.1 s so với 5.2 s của một crossfade, nhanh khoảng 5 lần so với CPU).
- Khởi động một `gpufx` mất khoảng 1 s (tạo device, biên dịch shader), nên clip ngắn được lợi ít hơn.
- Chưa đo: frame Vulkan suốt đường (`-hwaccel vulkan` → gpufx → encode trên GPU), bỏ được upload và readback.

