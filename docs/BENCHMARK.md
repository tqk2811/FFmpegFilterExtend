# Benchmark

[Tiếng Việt](BENCHMARK-vi.md) · [README](../README.md)

Build `577bd42` (win64 release package), measured on 2026-10-14.

- **Machine**: Intel Core i9-14900HX, 32 GiB DDR5-5600 (2 × 16 GiB), NVIDIA GeForce RTX 4060 Laptop GPU
  8 GiB VRAM (driver 617.42), Windows 11 Pro. The desktop was idle during the runs (nothing else using the GPU),
  so the spread between runs is narrow.
- **Input**: two H.264 clips, 1920×1080, 23.976 fps, 90 s each (2158 frames), software decode, output to
  `-f null`. gpufx picks the API from the input frames or `-filter_hw_device`.
- **Frame path**: `gpufx` outputs GPU frames only and uploads software input itself on the device given by
  `-filter_hw_device`. Every gpufx command here therefore has `-init_hw_device` / `-filter_hw_device` and ends with
  `hwdownload` (or `gpufx_download`) so the next step gets CPU frames; the upload and the readback are part of
  the times. Example:
  `-init_hw_device vulkan=vk -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex "[0][1]gpufx=effect=crossfade.zip,hwdownload,format=yuv420p"`.
  The chain and transfer rows create the Vulkan device with `vulkan=vk:0,disable_multiplane=1`. The D3D row uses
  D3D11 frames, the D3D frame type FFmpeg uses throughout (`-init_hw_device d3d11va=dx:0`); gpufx runs its
  shaders on D3D12 of the same adapter (wgpu has no D3D11 backend) and chooses the API itself; `hwdownload` then
  needs `format=nv12`.
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
| gpufx `crossfade.zip`, D3D11 frames (shaders on D3D12) | 7.93 s | 497 MB | 192 / 105 MB |
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

## Joining six clips with five transitions

Build `c62d150` (win64 bundle), measured on 2026-10-15, same machine as above.

- **Input**: six H.264 clips A–F made from `testsrc2`, each with its RGB channels in another order (CRF 12,
  yuv420p, BT.709 limited range), 1920×1080, 30 fps, 10 s each (300 frames). A 1 s fade at each of the 5 joins:
  output 55 s, 1650 frames, `-f null`. Software decode in every row.
- **Three ways** (the full filter scripts are passed with `-/filter_complex <file>`):
  1. CPU: FFmpeg 8.0.1, chain of 5 `xfade=transition=fade:duration=1:offset=9|18|27|36|45`, then
     `format=yuv420p`.
  2. Five separate `gpufx`, one per join, each on only while its transition runs:
     `[x1][u2]gpufx=effect=effects/crossfade.zip:params='progress=clip(t-18\,0\,1)':enable='between(t,18,19)':bypass=auto[x2]`.
     Outside its window a filter hands on its input texture relabelled (`passthrough=auto`): input 0 before
     the transition and the incoming clip after it (`bypass=auto`).
  3. One `gpufx` with a graph of 5 crossfades, each switched by `<node>.enable` / `<node>.bypass`:
     `[u0]...[u5]gpufx=graph='[0][1]effects/crossfade.zip[x1]; [x1][2]effects/crossfade.zip[x2]; ...[out]':params='x1.progress=clip(t-9\,0\,1)|x1.enable=between(t\,9\,10)|x1.bypass=auto|...'`.
- **Inputs of the gpufx ways**: each clip is uploaded once (`gpufx_upload`, Vulkan device
  `vulkan=vk:0,disable_multiplane=1`) and shifted to its join (`setpts=PTS+9*k/TB`). Clip A is held on its last
  frame with `tpad=stop_mode=clone:stop_duration=45` (GPU frames, nothing uploaded again), because the first input
  sets the length of a gpufx; a clip that has not started yet is a black frame and is never shown. The output goes
  through `gpufx_download,format=yuv420p`. D3D rows: `-init_hw_device d3d11va=dx:0`, `format=nv12,hwupload` and
  `hwdownload,format=nv12`.
- Median of 3 runs per column; wall time measured around the process, `utime`/`rtime`/`maxrss` from
  `-benchmark`. fps = 1650 / wall time.

| Way | Wall | fps | rtime | utime | maxrss |
|---|---|---|---|---|---|
| Decode only (6 clips, no filter) | 1.07 s | – | 0.87 s | 20.3 s | 868 MB |
| 1. 5 × `xfade` fade (CPU, FFmpeg 8.0.1) | 3.19 s | 518 | 2.96 s | 27.3 s | 1618 MB |
| 2. 5 × `gpufx` + `enable`/`bypass=auto`, Vulkan | 2.62 s | 631 | 1.96 s | 13.8 s | 845 MB |
| 3. one `gpufx` graph + `<node>.enable`/`.bypass`, Vulkan | **2.61 s** | 632 | 2.00 s | 13.3 s | 847 MB |
| 2., without `gpufx_download` | 2.63 s | 627 | 1.96 s | 13.7 s | 836 MB |
| 3., without `gpufx_download` | 3.43 s (2.7–3.8) | 482 | 2.60 s | 17.6 s | 831 MB |
| 2., `passthrough=off` (GPU copy while off) | 5.83 s | 283 | 4.94 s | 16.9 s | 873 MB |
| 2., D3D11 frames, `hwupload`/`hwdownload` | 5.10 s | 323 | 4.67 s | 15.9 s | 938 MB |
| 3., D3D11 frames, `hwupload`/`hwdownload` | 5.07 s | 325 | 4.61 s | 15.6 s | 938 MB |

**Correctness**: the outputs of ways 2 and 3 are bit identical (Vulkan and D3D11 alike). Outside the
transitions they equal the decoded clips bit for bit (relabelled frames, no conversion). `crossfade.zip` mixes
with `smoothstep(progress)`, not linearly like `xfade` fade, so it was checked against
`xfade=transition=custom` with the same curve: PSNR 47.0 dB average, 45.3 dB minimum over the 155 transition
frames (YUV → RGBA → YUV and rounding); 46.4 dB over the other frames, where `xfade` itself converts to yuv444p
and back. Against the linear `fade` the transition frames drop to 26.8 dB in the middle of each half, as
expected from the different curve.

What the numbers say:

- Five transitions in a 55 s join: gpufx is about 1.2× faster than the CPU in wall time and needs half the CPU
  time and half the RAM. The run is bound by decoding the six clips; the shaders run for only 155 of 1650 frames.
- Five separate gpufx with `enable=` and one graph with `<node>.enable` cost the same: while off, a filter
  hands its texture on without a copy, so a chain of disabled filters is nearly free.
- `passthrough=off` makes each disabled filter copy (and convert) the frame on the GPU: 2.2× slower, and the
  YUV → RGBA → YUV round trip of every copy lowers the chroma (PSNR 37 dB against the relabelled output).
- Dropping `gpufx_download` gains nothing: its copies already overlap the rest.
- D3D11 frames are about 2× slower than Vulkan here (`hwupload`/`hwdownload` wait for every copy, see above).
