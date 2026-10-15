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

## Filter nặng hơn: effect đơn, chuyển cảnh và chuỗi xếp chồng

Build `de39c81` (bundle win64), đo ngày 2026-10-15, cùng máy như trên (Intel Core i9-14900HX, 24 core /
32 thread, RTX 4060 Laptop). Các dòng CPU chạy FFmpeg 8.0.1 tham chiếu (bundle FFmpeg 9.0 không có `xfade`,
`gblur`, `unsharp`, `eq`, `bilateral`...), `-threads` mặc định. Các dòng GPU: bundle, device Vulkan
`vulkan=vk:0,disable_multiplane=1`, `gpufx_upload` → `gpufx` → `gpufx_download,format=yuv420p`. `-f null`, trung vị
của 3 lần chạy, wall time đo quanh tiến trình; fps = số frame / wall time.

- **Input**: clip A và B của mục trên (1920×1080, 30 fps, 300 frame), mỗi clip đọc 3 lần bằng `-stream_loop 2`
  (900 frame, 30 s). Hai nguồn: file yuv420p thô đã decode sẵn (`-f rawvideo`, không tốn decode) và clip H.264
  (decode bằng phần mềm).
- **Các cặp** (cùng tham số ở hai phía khi filter có tham số đó; phép tính không giống hệt):

| Ca | CPU (FFmpeg 8.0.1) | gpufx |
|---|---|---|
| Gaussian blur, lớn | `gblur=sigma=24` | `gaussian-blur` `radius=48` (σ = 24, 97 tap mỗi pass) |
| Gaussian blur, nhỏ | `gblur=sigma=3` | `gaussian-blur` `radius=6` |
| Sharpen | `unsharp=3:3:0.8:3:3:0.8` | `sharpen` `amount=0.8` |
| Màu | `eq=contrast=1.2:saturation=1.3:gamma=1.1,hue=h=20` | `color-adjust` cùng giá trị |
| Vignette | `vignette` | `vignette` `strength=0.6` |
| Bilateral | `bilateral=sigmaS=4:sigmaR=0.1` | bilateral 17×17 vét cạn viết riêng cho bài đo (không phát hành) |
| Chuyển cảnh suốt 30 s | `xfade=transition=dissolve\|pixelize\|circleopen\|zoomin:duration=30:offset=0` | `dissolve`, `pixelize-transition`, `circle-reveal`, `zoom-transition`, `progress=t/30` |

| Ca | CPU thô | gpufx thô | ×, thô | CPU H.264 | gpufx H.264 | ×, H.264 | CPU utime (thô) |
|---|---|---|---|---|---|---|---|
| Không filter: chỉ đọc / `gpufx_upload,gpufx_download` | 0.89 s | 1.42 s | – | 0.92 s | 1.45 s | – | 0.0 s |
| `gblur` σ 24 / `gaussian-blur` 48 | 2.00 s | 2.73 s | 0.73 | 2.42 s | 2.79 s | 0.87 | 4.6 s |
| `gblur` σ 3 / `gaussian-blur` 6 | 2.94 s | 1.58 s | 1.86 | 3.10 s | 1.68 s | 1.85 | 11.5 s |
| `unsharp` / `sharpen` | 1.36 s | 1.46 s | 0.93 | 1.59 s | 1.57 s | 1.01 | 9.4 s |
| `eq,hue` / `color-adjust` | 0.92 s | 1.46 s | 0.63 | 1.21 s | 1.54 s | 0.79 | 0.7 s |
| `vignette` / `vignette` | 3.49 s | 1.51 s | 2.31 | 3.59 s | 1.59 s | 2.26 | 3.1 s |
| `bilateral` / bilateral 17×17 | 2.74 s | 4.04 s | 0.68 | 2.85 s | 4.08 s | 0.70 | 22.5 s |
| `xfade` dissolve / `dissolve` | 5.88 s | 1.83 s | **3.21** | 6.24 s | 2.39 s | 2.61 | 54.2 s |
| `xfade` pixelize / `pixelize-transition` | 4.15 s | 1.78 s | 2.33 | 4.67 s | 2.28 s | 2.05 | 30.8 s |
| `xfade` circleopen / `circle-reveal` | 5.19 s | 1.78 s | 2.92 | 5.37 s | 2.22 s | 2.42 | 51.3 s |
| `xfade` zoomin / `zoom-transition` | 3.71 s | 1.81 s | 2.05 | 3.96 s | 2.26 s | 1.75 | 21.4 s |

× = wall CPU / wall gpufx. Tiến trình gpufx dùng dưới 1 s CPU time với input thô (khoảng 7 s với H.264, phần đó là
decoder); RAM khoảng 0.42 GB với gpufx so với 0.1–0.37 GB ở CPU.

**Nối sáu clip với năm chuyển cảnh** (cùng thiết lập như mục trên, chỉ đổi chuyển cảnh; chain = 5 `gpufx` với
`enable`/`bypass=auto`, graph = một `gpufx` với `<node>.enable`/`.bypass`):

| Chuyển cảnh | CPU `xfade` | gpufx chain | gpufx graph | CPU utime / gpufx utime | maxrss CPU / gpufx |
|---|---|---|---|---|---|
| dissolve | 3.82 s (432 fps) | 3.32 s (497 fps) | **2.72 s** (607 fps) | 37.1 s / 14.9 s | 1578 / 825 MB |
| pixelize | 3.42 s (482 fps) | **2.56 s** (645 fps) | 2.58 s (640 fps) | 33.1 s / 13.1 s | 1595 / 824 MB |

**Chuỗi xếp chồng**: trên mỗi input Gaussian blur (σ 3) + sharpen + màu, rồi chuyển cảnh hình tròn suốt 30 s,
rồi vignette. CPU: `[0]gblur=sigma=3,unsharp=3:3:0.8:3:3:0.8,eq=...,hue=h=20[a]; [1]...[b];
[a][b]xfade=transition=circleopen:duration=30:offset=0,vignette`. gpufx: một `gpufx` với graph 8 node
`[0]gaussian-blur[a0]; [a0]sharpen[a1]; [a1]color-adjust[a2]; [1]...[b2]; [a2][b2]circle-reveal[t]; [t]vignette[out]`.
4K: hai clip scale lên 3840×2160 rồi encode lại H.264 (CRF 14), mỗi clip 900 frame.

| Nguồn | CPU | gpufx graph | × | CPU utime / gpufx utime | maxrss CPU / gpufx |
|---|---|---|---|---|---|
| 1080p thô | 22.90 s (39 fps) | 2.48 s (362 fps) | **9.2** | 93.4 s / 0.8 s | 527 / 471 MB |
| 1080p H.264 | 23.27 s (39 fps) | 2.63 s (342 fps) | 8.8 | 102.5 s / 12.7 s | 829 / 673 MB |
| 4K H.264 (chỉ decode: 2.64 s) | 87.16 s (10 fps) | 8.85 s (102 fps) | **9.8** | 395.5 s / 41.9 s | 3044 / 1761 MB |

**Độ đúng** (frame 150, CPU so với gpufx; chuyển cảnh dùng `duration=10` nên progress 0.5): các effect không
tính cùng một phép, nên đây chỉ là kiểm thô kèm xem hai frame cạnh nhau. PSNR: bilateral 41.3 dB, blur nhỏ
39.6 dB, sharpen 36.0 dB, blur lớn 34.1 dB, vignette 30.5 dB (đường giảm sáng khác), màu 20.3 dB (mô hình hue
khác); các chuyển cảnh khác nhau theo thiết kế (`xfade` circleopen là dải chuyển mềm rộng, `circle-reveal` là
vòng tròn sắc nét; `xfade` zoomin ở thời điểm khác) và các chuyển cảnh ngẫu nhiên dùng mẫu khác. File yuv thô
không có tag màu: khi đó `gpufx` đọc chúng với matrix/range khác (vòng upload/download chỉ còn 25 dB), nên lúc
kiểm đã gắn tag bằng `setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709` (vòng
upload/download 41.9 dB, bằng clip H.264). Các lần đo thời gian dùng file chưa gắn tag; khối lượng việc mỗi
frame là như nhau.

Các con số cho thấy:

- Một filter rẻ không bù được chi phí đưa frame lên GPU: riêng upload + download đã mất 1.42 s cho 900 frame
  (635 fps), lâu hơn `eq,hue`, `unsharp` hay `gblur` σ 24 trên 32 thread. `gblur` là filter IIR, chi phí không tăng
  theo σ, còn `gaussian-blur` 48 chạy 97 tap mỗi pass; bilateral 17×17 (289 tap) chậm hơn `bilateral` O(1) của
  FFmpeg cũng vì vậy. GPU thắng khi filter CPU chậm trên từng pixel: `vignette` 2.3 lần, `gblur` σ 3 1.9 lần.
- Chuyển cảnh chạy suốt clip nhanh hơn 2–3.2 lần với gpufx và gần như không tốn CPU (`xfade` tốn 21–54 s CPU time
  cho 900 frame).
- Khi nối sáu clip, chuyển cảnh chỉ phủ 155 trên 1650 frame nên chỉ nhanh hơn 1.15–1.4 lần (nghẽn ở decode),
  giống với fade.
- Xếp chồng filter là chỗ GPU có lợi: graph 8 effect nhanh hơn 9–10 lần ở 1080p và 4K. Frame chỉ lên và xuống
  GPU một lần, mọi bước chạy trên GPU, CPU chỉ decode. Ở 4K đường CPU chỉ chạy 10 fps.
