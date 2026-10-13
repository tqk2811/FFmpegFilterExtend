# Benchmark

[Tiếng Việt](BENCHMARK-vi.md) · [README](../README.md)

Build `b1531dc` (win64 release package), measured on 2026-10-13.

- **Machine**: Intel Core i9-14900HX, 32 GiB DDR5-5600 (2 × 16 GiB), NVIDIA GeForce RTX 4060 Laptop GPU
  8 GiB VRAM (driver 617.42), Windows 11 Pro.
- **Input**: two H.264 clips, 1920×1080, 23.976 fps, 90 s each (2158 frames), software decode, output to
  `-f null`. gpufx picks Vulkan by default on Windows (`backend=auto`).
- **Comparison**: FFmpeg 8.0.1 (gpl-shared build) with its own CPU filters. The transition runs over
  the first 60 s (`xfade` refuses `duration` above 60 s); gpufx uses `progress=clip(t/60,0,1)`.
- Time is the best of 3 runs. RAM is the peak working set; VRAM is the peak of the Windows
  "GPU Process Memory" counters (dedicated / shared).

**One transition**

| Filter | Time | Peak RAM | VRAM ded. / shared |
|---|---|---|---|
| Decode only (no filter) | 2.18 s | 309 MB | 0 |
| `xfade` fade (CPU) | 3.49 s | 587 MB | 0 |
| `xfade` wipeleft (CPU) | 3.12 s | – | 0 |
| `xfade` circleopen (CPU) | 8.00 s | 549 MB | 0 |
| `xfade_vulkan` fade (hwupload/hwdownload) | 5.33 s | – | 399 / 80 MB |
| gpufx `crossfade.zip`, Vulkan | 5.19 s | 491 MB | 201 / – |
| gpufx `crossfade.zip`, DX12 | 7.26 s | 546 MB | 173 / 154 MB |
| gpufx `wipe-transition.zip`, Vulkan | 5.22 s | 490 MB | 201 / – |
| gpufx `circle-reveal.zip`, Vulkan | 5.16 s | 488 MB | 202 / – |

**A chain of effects**: clip A blur → color adjust → vignette, clip B sepia → sharpen → vignette, crossfade,
then sharpen. The CPU side uses `gblur`, `eq`, `vignette`, `colorchannelmixer`, `unsharp`, `xfade`.

| Filter | Time | Peak RAM | VRAM ded. / shared |
|---|---|---|---|
| CPU filters | 34.95 s | 655 MB | 0 |
| 8 separate `gpufx`, software frames (each uploads and reads back) | 29.77 s | 586 MB | 202 / – |
| one `gpufx=graph=...` | **7.05 s** | 491 MB | 202 / – |

With software frames every separate `gpufx` uploads its input and reads its output back. Uploading once in
front keeps the frames on the GPU between the filters: see the chain rows of the next table (5.95–13.27 s).

**Vulkan frames and the transfer filters** (same machine, 2026-10-13, range of 3 runs, normal desktop running (browser, Discord, Steam; a few % GPU load), so spread is wide; RAM is
the peak working set, VRAM the dedicated peak of the 3rd run). Rows of the first two tables that name gpufx were re-measured on this build (VRAM shared not re-measured); CPU, `xfade_vulkan` and DX12 rows are from the earlier build. Transfers: clip A only, nv12, 90 s.

| Filter | Time | Peak RAM | VRAM ded. |
|---|---|---|---|
| Decode only (nv12) | 1.92–2.07 s | 262 MB | 16 MB |
| `hwupload,hwdownload` | 3.63–4.11 s | 280 MB | 26 MB |
| `gpufx_upload,hwdownload` | 3.28–4.09 s | 284 MB | 32 MB |
| `hwupload,gpufx_download` | 2.39–3.07 s | 297 MB | 35 MB |
| `gpufx_upload,gpufx_download` | 2.23–3.07 s | 289 MB | 32 MB |
| Chain, 8 separate `gpufx`, hwupload/hwdownload | 9.83–13.27 s | 547 MB | 316 MB |
| Chain, 8 separate `gpufx`, gpufx_upload/download | 8.97–15.51 s | 559 MB | 320 MB |
| Chain, 8 separate, `out_format=rgba`, hwupload/hwdownload | 9.19–15.23 s | 542 MB | 419 MB |
| Chain, 8 separate, `out_format=rgba`, gpufx_upload/download | 5.95–8.26 s | 527 MB | 421 MB |
| Chain, one `graph=`, hwupload/hwdownload | 8.88–10.82 s | 509 MB | 253 MB |
| Chain, one `graph=`, gpufx_upload/download | **5.32–6.13 s** | 479 MB | 256 MB |

`gpufx_download` removes most of the readback cost (`hwdownload` waits for every copy); the upload side
gains little since `hwupload` does not wait either.

What the numbers say:

- With frames in system memory each `gpufx` instance costs about 1.5 ms per frame whatever the shader does:
  upload, YUV → RGBA on the GPU, readback and the wait for the GPU. The pixel format conversion runs in a shader,
  FFmpeg inserts no `scale` filter. A light transition alone is therefore slower than `xfade` on a fast CPU.
- Put the whole chain in one `gpufx` (`graph=` or `effect='a.zip|b.zip'`): the frames cross the bus once and
  extra effects are nearly free (8 effects: 7.1 s against 5.2 s for one crossfade, about 5× faster than CPU).
- Starting a `gpufx` costs about 1 s (device creation and shader compilation), so short clips gain less.
- Not measured yet: Vulkan hw frames end to end (`-hwaccel vulkan` → gpufx → GPU encode), which skips the
  upload and readback.

