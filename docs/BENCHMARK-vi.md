# Đo tốc độ

[English](BENCHMARK.md) · [README](../README-vi.md)

Bản build `577bd42` (gói release win64), đo ngày 2026-10-14.

- **Máy**: Intel Core i9-14900HX, RAM 32 GiB DDR5-5600 (2 × 16 GiB), NVIDIA GeForce RTX 4060 Laptop GPU
  8 GiB VRAM (driver 617.42), Windows 11 Pro. Desktop rảnh trong lúc đo (không có gì khác dùng GPU), nên các lần
  chạy lệch nhau ít.
- **Input**: hai clip H.264, 1920×1080, 23.976 fps, mỗi clip 90 s (2158 frame), decode bằng CPU, ghi ra
  `-f null`. gpufx tự chọn API theo frame input hoặc `-filter_hw_device`.
- **Đường frame**: `gpufx` chỉ trả ra frame GPU và tự upload input CPU lên device chỉ định bởi
  `-filter_hw_device`. Vì vậy mọi lệnh gpufx ở đây đều có `-init_hw_device` / `-filter_hw_device` và kết thúc bằng
  `hwdownload` (hoặc `gpufx_download`) để bước sau nhận frame CPU; upload và readback nằm trong thời gian đo. Ví dụ:
  `-init_hw_device vulkan=vk -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex "[0][1]gpufx=effect=crossfade.zip,hwdownload,format=yuv420p"`.
  Các dòng chuỗi và truyền frame tạo device Vulkan bằng `vulkan=vk:0,disable_multiplane=1`. Dòng D3D dùng frame
  D3D11, loại frame D3D mà FFmpeg dùng khắp nơi (`-init_hw_device d3d11va=dx:0`); gpufx chạy shader trên D3D12 của
  cùng adapter (wgpu không có backend D3D11) và tự chọn API; `hwdownload` khi đó cần `format=nv12`.
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
| gpufx `crossfade.zip`, frame D3D11 (shader chạy trên D3D12) | 7.93 s | 497 MB | 192 / 105 MB |
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

## Nối sáu clip với năm chuyển cảnh

Bản build `c62d150` (bundle win64), đo ngày 2026-10-15, cùng máy như trên.

- **Input**: sáu clip H.264 A–F tạo từ `testsrc2`, mỗi clip đảo thứ tự kênh RGB khác nhau (CRF 12, yuv420p,
  BT.709 limited range), 1920×1080, 30 fps, mỗi clip 10 s (300 frame). Fade 1 s ở mỗi chỗ nối trong 5 chỗ nối:
  output 55 s, 1650 frame, `-f null`. Mọi dòng đều decode bằng CPU.
- **Ba cách** (script filter đầy đủ truyền bằng `-/filter_complex <file>`):
  1. CPU: FFmpeg 8.0.1, chuỗi 5 `xfade=transition=fade:duration=1:offset=9|18|27|36|45`, rồi `format=yuv420p`.
  2. Năm `gpufx` riêng, mỗi chỗ nối một filter, chỉ bật trong lúc chuyển cảnh của nó:
     `[x1][u2]gpufx=effect=effects/crossfade.zip:params='progress=clip(t-18\,0\,1)':enable='between(t,18,19)':bypass=auto[x2]`.
     Ngoài cửa sổ, filter chuyền texture input đi dưới nhãn mới (`passthrough=auto`, không copy): input 0 trước
     chuyển cảnh và clip mới sau chuyển cảnh (`bypass=auto`).
  3. Một `gpufx` với graph gồm 5 crossfade, bật tắt từng node bằng `<node>.enable` / `<node>.bypass`:
     `[u0]...[u5]gpufx=graph='[0][1]effects/crossfade.zip[x1]; [x1][2]effects/crossfade.zip[x2]; ...[out]':params='x1.progress=clip(t-9\,0\,1)|x1.enable=between(t\,9\,10)|x1.bypass=auto|...'`.
- **Input của hai cách gpufx**: mỗi clip upload một lần (`gpufx_upload`, device Vulkan
  `vulkan=vk:0,disable_multiplane=1`) rồi dời tới chỗ nối của nó (`setpts=PTS+9*k/TB`). Clip A giữ frame cuối bằng
  `tpad=stop_mode=clone:stop_duration=45` (frame GPU, không upload lại), vì input đầu quyết định độ dài của gpufx;
  clip chưa bắt đầu là frame đen và không bao giờ được hiện. Output qua `gpufx_download,format=yuv420p`. Dòng D3D:
  `-init_hw_device d3d11va=dx:0`, `format=nv12,hwupload` và `hwdownload,format=nv12`.
- Lấy trung vị của 3 lần cho từng cột; thời gian thực đo bao quanh tiến trình, `utime`/`rtime`/`maxrss` lấy từ
  `-benchmark`. fps = 1650 / thời gian thực.

| Cách | Thời gian | fps | rtime | utime | maxrss |
|---|---|---|---|---|---|
| Chỉ decode (6 clip, không filter) | 1.07 s | – | 0.87 s | 20.3 s | 868 MB |
| 1. 5 × `xfade` fade (CPU, FFmpeg 8.0.1) | 3.19 s | 518 | 2.96 s | 27.3 s | 1618 MB |
| 2. 5 × `gpufx` + `enable`/`bypass=auto`, Vulkan | 2.62 s | 631 | 1.96 s | 13.8 s | 845 MB |
| 3. một graph `gpufx` + `<node>.enable`/`.bypass`, Vulkan | **2.61 s** | 632 | 2.00 s | 13.3 s | 847 MB |
| 2., không `gpufx_download` | 2.63 s | 627 | 1.96 s | 13.7 s | 836 MB |
| 3., không `gpufx_download` | 3.43 s (2.7–3.8) | 482 | 2.60 s | 17.6 s | 831 MB |
| 2., `passthrough=off` (copy trên GPU khi tắt) | 5.83 s | 283 | 4.94 s | 16.9 s | 873 MB |
| 2., frame D3D11, `hwupload`/`hwdownload` | 5.10 s | 323 | 4.67 s | 15.9 s | 938 MB |
| 3., frame D3D11, `hwupload`/`hwdownload` | 5.07 s | 325 | 4.61 s | 15.6 s | 938 MB |

**Độ đúng**: output của cách 2 và 3 giống nhau từng bit (cả Vulkan lẫn D3D11). Ngoài các đoạn chuyển cảnh, chúng
giống từng bit với clip đã decode (frame chỉ đổi nhãn, không chuyển đổi). `crossfade.zip` trộn theo
`smoothstep(progress)` chứ không tuyến tính như `xfade` fade, nên được so với `xfade=transition=custom` cùng đường
cong: PSNR trung bình 47.0 dB, thấp nhất 45.3 dB trên 155 frame chuyển cảnh (YUV → RGBA → YUV và làm tròn); 46.4 dB
ở các frame còn lại, nơi chính `xfade` đổi sang yuv444p rồi đổi lại. So với `fade` tuyến tính thì frame chuyển cảnh
xuống 26.8 dB ở giữa mỗi nửa, đúng như dự kiến vì khác đường cong.

Nhận xét:

- Năm chuyển cảnh trong 55 s: gpufx nhanh hơn CPU khoảng 1.2 lần về thời gian thực, tốn một nửa thời gian CPU và
  một nửa RAM. Phần chậm nhất là decode sáu clip; shader chỉ chạy ở 155 trên 1650 frame.
- Năm `gpufx` riêng với `enable=` và một graph với `<node>.enable` tốn như nhau: khi tắt, filter chuyền texture đi
  không copy, nên một chuỗi filter đang tắt gần như không tốn gì.
- `passthrough=off` bắt mỗi filter đang tắt copy (và chuyển đổi) frame trên GPU: chậm hơn 2.2 lần, và vòng
  YUV → RGBA → YUV của mỗi lần copy làm giảm chroma (PSNR 37 dB so với output đổi nhãn).
- Bỏ `gpufx_download` không nhanh hơn: các lần copy của nó vốn đã chạy chồng lên phần còn lại.
- Frame D3D11 chậm hơn Vulkan khoảng 2 lần ở đây (`hwupload`/`hwdownload` chờ từng lần copy, xem ở trên).
