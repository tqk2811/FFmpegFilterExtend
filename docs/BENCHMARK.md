# Benchmark

[Tiếng Việt](BENCHMARK-vi.md) · [README](../README.md)

Build `577bd42` (win64 release package), measured on 2026-10-14.

- **Machine**: Intel Core i9-14900HX, 32 GiB DDR5-5600 (2 × 16 GiB), NVIDIA GeForce RTX 4060 Laptop GPU
  8 GiB VRAM (driver 617.42), Windows 11 Pro. The desktop was idle during the runs (nothing else using the GPU),
  so the spread between runs is narrow.
- **Input**: two H.264 clips, 1920×1080, 23.976 fps, 90 s each (2158 frames), software decode, output to
  `-f null`. gpufx picks Vulkan by default on Windows (`backend=auto`).
- **Frame path**: `gpufx` outputs GPU frames only and uploads software input itself on the device given by
  `-filter_hw_device`. Every gpufx command here therefore has `-init_hw_device` / `-filter_hw_device` and ends with
  `hwdownload` (or `gpufx_download`) so the next step gets CPU frames; the upload and the readback are part of
  the times. Example:
  `-init_hw_device vulkan=vk -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex "[0][1]gpufx=effect=crossfade.zip,hwdownload,format=yuv420p"`.
  The chain and transfer rows create the Vulkan device with `vulkan=vk:0,disable_multiplane=1`. The FFmpeg of the
  bundle has no `d3d12va`, so the D3D row uses D3D11 frames (`-init_hw_device d3d11va=dx:0`), which gpufx
  processes with its DX12 backend (`backend=dx12`); `hwdownload` then needs `format=nv12`. `backend=gl` no longer
  exists in the filter.
- **Comparison**: FFmpeg 8.0.1 (gpl-shared build) with its own CPU filters. The transition runs over
  the first 60 s (`xfade` refuses `duration` above 60 s); gpufx uses `progress=clip(t/60,0,1)`.
- Time is the best of 3 runs. RAM is the peak working set and VRAM the peak of the Windows
  "GPU Process Memory" counters (dedicated / shared), both of the 3rd run.

**One transition**

| Filter | Time | Peak RAM | VRAM ded. / shared |
|---|---|---|---|
| Decode only (no filter) | 1.52 s | 344 MB | 0 |
| `xfade` fade (CPU) | 2.64 s | 593 MB | 0 |
| `xfade` wipeleft (CPU) | 2.54 s | 580 MB | 0 |
| `xfade` circleopen (CPU) | 6.72 s | 540 MB | 0 |
| `xfade_vulkan` fade (hwupload/hwdownload) | 5.04 s | 527 MB | 399 / 80 MB |
| gpufx `crossfade.zip`, Vulkan | 5.10 s | 467 MB | 253 / 89 MB |
| gpufx `crossfade.zip`, D3D11 frames (DX12 backend) | 7.93 s | 497 MB | 192 / 105 MB |
| gpufx `wipe-transition.zip`, Vulkan | 5.07 s | 468 MB | 253 / 89 MB |
| gpufx `circle-reveal.zip`, Vulkan | 5.08 s | 468 MB | 253 / 89 MB |

**A chain of effects**: clip A blur → color adjust → vignette, clip B sepia → sharpen → vignette, crossfade,
then sharpen. The CPU side uses `gblur`, `eq`, `vignette`, `colorchannelmixer`, `unsharp`, `xfade`. The gpufx rows
are Vulkan frames; the times are the fastest of the 3 runs of the next table (or the same measurement, for the
two rows where gpufx uploads the input itself).

| Filter | Time | Peak RAM | VRAM ded. / shared |
|---|---|---|---|
| CPU filters | 34.24 s | 596 MB | 0 |
| 8 separate `gpufx` (the first one uploads), `hwdownload` | 10.46 s | 532 MB | 320 / 99 MB |
| `hwupload`, 8 separate `gpufx`, `hwdownload` | 10.59 s | 510 MB | 318 / 99 MB |
| `gpufx_upload`, 8 separate `gpufx` with `out_format=rgba`, `gpufx_download` | 5.64 s | 522 MB | 423 / 100 MB |
| one `gpufx=graph=...` (uploads the input itself), `hwdownload` | 6.70 s | 471 MB | 254 / 89 MB |
| `gpufx_upload`, one `gpufx=graph=...`, `gpufx_download` | **5.15 s** | 475 MB | 256 / 83 MB |

The old row "8 separate `gpufx` on software frames" (each filter uploading and reading back, 29.77 s on build
`b1531dc`) is gone: `gpufx` cannot take software frames in and give them back any more. Separate filters now
upload once, keep the frames on the GPU between them, and one `hwdownload` ends the chain.

**Vulkan frames and the transfer filters** (same machine, 2026-10-14, range of 3 runs, desktop idle; RAM is the
peak working set, VRAM the dedicated peak of the 3rd run). All rows of the tables above and below were measured on
this build. Transfers: clip A only, nv12, 90 s.

| Filter | Time | Peak RAM | VRAM ded. |
|---|---|---|---|
| Decode only (nv12) | 1.51–2.07 s | 257 MB | 16 MB |
| `hwupload,hwdownload` | 3.26–4.08 s | 275 MB | 26 MB |
| `gpufx_upload,hwdownload` | 3.09–3.14 s | 276 MB | 32 MB |
| `hwupload,gpufx_download` | 2.25–3.09 s | 289 MB | 35 MB |
| `gpufx_upload,gpufx_download` | 1.96–2.06 s | 284 MB | 32 MB |
| Chain, 8 separate `gpufx`, hwupload/hwdownload | 10.59–11.14 s | 510 MB | 318 MB |
| Chain, 8 separate `gpufx`, gpufx_upload/download | 9.37–10.17 s | 524 MB | 320 MB |
| Chain, 8 separate, `out_format=rgba`, hwupload/hwdownload | 7.30–8.13 s | 533 MB | 455 MB |
| Chain, 8 separate, `out_format=rgba`, gpufx_upload/download | 5.64–6.12 s | 522 MB | 423 MB |
| Chain, one `graph=`, hwupload/hwdownload | 7.28–8.11 s | 478 MB | 253 MB |
| Chain, one `graph=`, gpufx_upload/download | **5.12–5.16 s** | 475 MB | 256 MB |

`gpufx_download` removes most of the readback cost (`hwdownload` waits for every copy); the upload side
gains little since `hwupload` does not wait either.

What the numbers say:

- One `gpufx` on software input costs about 1.7 ms per frame over plain decoding (5.1 s against 1.5 s): upload,
  YUV → RGBA on the GPU, the shader, readback and the wait for the GPU. The pixel format conversion runs in a
  shader, FFmpeg inserts no `scale` filter. A light transition alone is therefore slower than `xfade` on a fast CPU.
- Put the whole chain in one `gpufx` (`graph=` or `effect='a.zip|b.zip'`): the frames cross the bus once and
  extra effects are nearly free (8 effects: 6.7 s, or 5.2 s with `gpufx_upload`/`gpufx_download`, against 5.1 s for
  one crossfade; 5–7× faster than CPU).
- Eight separate `gpufx` pass GPU frames between them but each one is a pass over the 1080p frame:
  10.5 s with `hwdownload`, 5.6 s with `out_format=rgba` and `gpufx_upload`/`gpufx_download`.
- Starting a `gpufx` costs about 0.4 s (device creation and shader compilation: 0.5 s for one frame against
  0.14 s for `xfade`), so short clips gain less.
- Not measured yet: Vulkan hw frames end to end (`-hwaccel vulkan` → gpufx → GPU encode), which skips the
  upload and readback.
