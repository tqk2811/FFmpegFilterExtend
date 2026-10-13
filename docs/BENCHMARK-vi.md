# Đo tốc độ

[English](BENCHMARK.md) · [README](../README-vi.md)

Bản build `577bd42` (gói release win64), đo ngày 2026-10-14.

- **Máy**: Intel Core i9-14900HX, RAM 32 GiB DDR5-5600 (2 × 16 GiB), NVIDIA GeForce RTX 4060 Laptop GPU
  8 GiB VRAM (driver 617.42), Windows 11 Pro. Desktop rảnh trong lúc đo (không có gì khác dùng GPU), nên các lần
  chạy lệch nhau ít.
- **Input**: hai clip H.264, 1920×1080, 23.976 fps, mỗi clip 90 s (2158 frame), decode bằng CPU, ghi ra
  `-f null`. Trên Windows gpufx mặc định chọn Vulkan (`backend=auto`).
- **Đường frame**: `gpufx` chỉ trả ra frame GPU và tự upload input CPU lên device chỉ định bởi
  `-filter_hw_device`. Vì vậy mọi lệnh gpufx ở đây đều có `-init_hw_device` / `-filter_hw_device` và kết thúc bằng
  `hwdownload` (hoặc `gpufx_download`) để bước sau nhận frame CPU; upload và readback nằm trong thời gian đo. Ví dụ:
  `-init_hw_device vulkan=vk -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex "[0][1]gpufx=effect=crossfade.zip,hwdownload,format=yuv420p"`.
  Các dòng chuỗi và truyền frame tạo device Vulkan bằng `vulkan=vk:0,disable_multiplane=1`. FFmpeg trong gói không
  có `d3d12va`, nên dòng D3D dùng frame D3D11 (`-init_hw_device d3d11va=dx:0`), gpufx xử lý bằng backend DX12
  (`backend=dx12`); `hwdownload` khi đó cần `format=nv12`. Filter không còn `backend=gl`.
- **So với**: FFmpeg 8.0.1 (bản gpl-shared) với filter CPU có sẵn. Chuyển cảnh chạy trong 60 s đầu (`xfade` không
  nhận `duration` quá 60 s); gpufx dùng `progress=clip(t/60,0,1)`.
- Thời gian lấy lần nhanh nhất trong 3 lần. RAM là working set đỉnh, VRAM là đỉnh của counter Windows
  "GPU Process Memory" (dedicated / shared), cả hai lấy ở lần chạy thứ 3.

**Một hiệu ứng chuyển cảnh**

| Filter | Thời gian | RAM đỉnh | VRAM ded. / shared |
|---|---|---|---|
| Chỉ decode (không filter) | 1.52 s | 344 MB | 0 |
| `xfade` fade (CPU) | 2.64 s | 593 MB | 0 |
| `xfade` wipeleft (CPU) | 2.54 s | 580 MB | 0 |
| `xfade` circleopen (CPU) | 6.72 s | 540 MB | 0 |
| `xfade_vulkan` fade (hwupload/hwdownload) | 5.04 s | 527 MB | 399 / 80 MB |
| gpufx `crossfade.zip`, Vulkan | 5.10 s | 467 MB | 253 / 89 MB |
| gpufx `crossfade.zip`, frame D3D11 (backend DX12) | 7.93 s | 497 MB | 192 / 105 MB |
| gpufx `wipe-transition.zip`, Vulkan | 5.07 s | 468 MB | 253 / 89 MB |
| gpufx `circle-reveal.zip`, Vulkan | 5.08 s | 468 MB | 253 / 89 MB |

**Chuỗi nhiều hiệu ứng**: clip A blur → chỉnh màu → vignette, clip B sepia → sharpen → vignette, crossfade, rồi
sharpen. Phía CPU dùng `gblur`, `eq`, `vignette`, `colorchannelmixer`, `unsharp`, `xfade`. Các dòng gpufx là frame
Vulkan; thời gian là lần nhanh nhất trong 3 lần chạy ở bảng sau (hoặc chính phép đo đó, với hai dòng để gpufx tự
upload input).

| Filter | Thời gian | RAM đỉnh | VRAM ded. / shared |
|---|---|---|---|
| Filter CPU | 34.24 s | 596 MB | 0 |
| 8 `gpufx` riêng (filter đầu upload), `hwdownload` | 10.46 s | 532 MB | 320 / 99 MB |
| `hwupload`, 8 `gpufx` riêng, `hwdownload` | 10.59 s | 510 MB | 318 / 99 MB |
| `gpufx_upload`, 8 `gpufx` riêng có `out_format=rgba`, `gpufx_download` | 5.64 s | 522 MB | 423 / 100 MB |
| một `gpufx=graph=...` (tự upload input), `hwdownload` | 6.70 s | 471 MB | 254 / 89 MB |
| `gpufx_upload`, một `gpufx=graph=...`, `gpufx_download` | **5.15 s** | 475 MB | 256 / 83 MB |

Dòng cũ "8 `gpufx` riêng trên frame CPU" (mỗi filter upload và readback, 29.77 s ở bản build `b1531dc`) đã bỏ:
`gpufx` không còn nhận frame CPU rồi trả frame CPU được nữa. Các filter riêng giờ upload một lần, giữ frame trên
GPU giữa các filter, và một `hwdownload` kết thúc chuỗi.

**Frame Vulkan và filter truyền frame** (cùng máy, 2026-10-14, khoảng của 3 lần chạy, desktop rảnh; RAM là
working set đỉnh, VRAM là dedicated đỉnh của lần 3). Mọi dòng ở các bảng trên và dưới đều đo trên bản build này.
Phần truyền: chỉ clip A, nv12, 90 s.

| Filter | Thời gian | RAM đỉnh | VRAM ded. |
|---|---|---|---|
| Chỉ decode (nv12) | 1.51–2.07 s | 257 MB | 16 MB |
| `hwupload,hwdownload` | 3.26–4.08 s | 275 MB | 26 MB |
| `gpufx_upload,hwdownload` | 3.09–3.14 s | 276 MB | 32 MB |
| `hwupload,gpufx_download` | 2.25–3.09 s | 289 MB | 35 MB |
| `gpufx_upload,gpufx_download` | 1.96–2.06 s | 284 MB | 32 MB |
| Chuỗi, 8 `gpufx` riêng, hwupload/hwdownload | 10.59–11.14 s | 510 MB | 318 MB |
| Chuỗi, 8 `gpufx` riêng, gpufx_upload/download | 9.37–10.17 s | 524 MB | 320 MB |
| Chuỗi, 8 riêng, `out_format=rgba`, hwupload/hwdownload | 7.30–8.13 s | 533 MB | 455 MB |
| Chuỗi, 8 riêng, `out_format=rgba`, gpufx_upload/download | 5.64–6.12 s | 522 MB | 423 MB |
| Chuỗi, một `graph=`, hwupload/hwdownload | 7.28–8.11 s | 478 MB | 253 MB |
| Chuỗi, một `graph=`, gpufx_upload/download | **5.12–5.16 s** | 475 MB | 256 MB |

`gpufx_download` bỏ được phần lớn chi phí readback (`hwdownload` chờ từng lần copy); phía upload
lợi ít vì `hwupload` vốn cũng không chờ.

Nhận xét:

- Một `gpufx` với input CPU tốn khoảng 1.7 ms mỗi frame so với chỉ decode (5.1 s so với 1.5 s): upload, đổi
  YUV → RGBA trên GPU, shader, readback và chờ GPU. Việc đổi pixel format chạy bằng shader, FFmpeg không chèn
  filter `scale`. Vì vậy một chuyển cảnh nhẹ đứng riêng chậm hơn `xfade` trên CPU mạnh.
- Gom cả chuỗi vào một `gpufx` (`graph=` hoặc `effect='a.zip|b.zip'`): frame chỉ qua bus một lần, thêm hiệu ứng gần
  như không tốn (8 hiệu ứng: 6.7 s, hoặc 5.2 s với `gpufx_upload`/`gpufx_download`, so với 5.1 s của một
  crossfade; nhanh gấp 5–7 lần CPU).
- 8 `gpufx` riêng chuyền frame GPU cho nhau nhưng mỗi filter là một lượt xử lý cả frame 1080p: 10.5 s với
  `hwdownload`, 5.6 s với `out_format=rgba` và `gpufx_upload`/`gpufx_download`.
- Khởi động một `gpufx` mất khoảng 0.4 s (tạo device, biên dịch shader: 0.5 s cho một frame so với 0.14 s của
  `xfade`), nên clip ngắn được lợi ít hơn.
- Chưa đo: frame Vulkan suốt đường (`-hwaccel vulkan` → gpufx → encode trên GPU), bỏ được upload và readback.
