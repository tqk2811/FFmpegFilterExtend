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
     `[x1][u2]gpufx=effect='effects/crossfade.zip=progress=clip(t-18\,0\,1)':enable='between(t,18,19)':bypass=auto[x2]`.
     Outside its window a filter hands on its input texture relabelled (`passthrough=auto`): input 0 before
     the transition and the incoming clip after it (`bypass=auto`).
  3. One `gpufx` with a graph of 5 crossfades, each switched by the inline `enable` / `bypass` keys:
     `[u0]...[u5]gpufx=graph='[0][1]effects/crossfade.zip=progress=clip(t-9\,0\,1)\:enable=between(t\,9\,10)\:bypass=auto[x1]; [x1][2]effects/crossfade.zip=progress=clip(t-18\,0\,1)\:enable=between(t\,18\,19)\:bypass=auto[x2]; ...[out]'`.
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
| 3. one `gpufx` graph + inline `enable`/`bypass`, Vulkan | **2.61 s** | 632 | 2.00 s | 13.3 s | 847 MB |
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
- Five separate gpufx with `enable=` and one graph with inline `enable` cost the same: while off, a filter
  hands its texture on without a copy, so a chain of disabled filters is nearly free.
- `passthrough=off` makes each disabled filter copy (and convert) the frame on the GPU: 2.2× slower, and the
  YUV → RGBA → YUV round trip of every copy lowers the chroma (PSNR 37 dB against the relabelled output).
- Dropping `gpufx_download` gains nothing: its copies already overlap the rest.
- D3D11 frames are about 2× slower than Vulkan here (`hwupload`/`hwdownload` wait for every copy, see above).

## Heavier filters: single effects, transitions and a stacked chain

Build `de39c81` (win64 bundle), measured on 2026-10-15, same machine as above (Intel Core i9-14900HX, 24 cores /
32 threads, RTX 4060 Laptop). The CPU rows run the reference FFmpeg 8.0.1 (the bundle, FFmpeg 9.0, has no `xfade`,
`gblur`, `unsharp`, `eq`, `bilateral`...), with default `-threads`. GPU rows: the bundle, Vulkan device
`vulkan=vk:0,disable_multiplane=1`, `gpufx_upload` → `gpufx` → `gpufx_download,format=yuv420p`. `-f null`, median of
3 runs, wall time measured around the process; fps = frames / wall time.

- **Input**: clips A and B of the section above (1920×1080, 30 fps, 300 frames), each read 3 times with
  `-stream_loop 2` (900 frames, 30 s). Two sources: raw yuv420p files decoded beforehand (`-f rawvideo`, no
  decode cost) and the H.264 clips (software decode).
- **Pairs** (same parameters on both sides where the filter has them; the math is not identical):

| Case | CPU (FFmpeg 8.0.1) | gpufx |
|---|---|---|
| Gaussian blur, large | `gblur=sigma=24` | `gaussian-blur` `radius=48` (σ = 24, 97 taps per pass) |
| Gaussian blur, small | `gblur=sigma=3` | `gaussian-blur` `radius=6` |
| Sharpen | `unsharp=3:3:0.8:3:3:0.8` | `sharpen` `amount=0.8` |
| Color | `eq=contrast=1.2:saturation=1.3:gamma=1.1,hue=h=20` | `color-adjust` same values |
| Vignette | `vignette` | `vignette` `strength=0.6` |
| Bilateral | `bilateral=sigmaS=4:sigmaR=0.1` | brute force 17×17 bilateral written for this test only (not shipped) |
| Transitions over the whole 30 s | `xfade=transition=dissolve\|pixelize\|circleopen\|zoomin:duration=30:offset=0` | `dissolve`, `pixelize-transition`, `circle-reveal`, `zoom-transition`, `progress=t/30` |

| Case | CPU raw | gpufx raw | ×, raw | CPU H.264 | gpufx H.264 | ×, H.264 | CPU utime (raw) |
|---|---|---|---|---|---|---|---|
| No filter: read only / `gpufx_upload,gpufx_download` | 0.89 s | 1.42 s | – | 0.92 s | 1.45 s | – | 0.0 s |
| `gblur` σ 24 / `gaussian-blur` 48 | 2.00 s | 2.73 s | 0.73 | 2.42 s | 2.79 s | 0.87 | 4.6 s |
| `gblur` σ 3 / `gaussian-blur` 6 | 2.94 s | 1.58 s | 1.86 | 3.10 s | 1.68 s | 1.85 | 11.5 s |
| `unsharp` / `sharpen` | 1.36 s | 1.46 s | 0.93 | 1.59 s | 1.57 s | 1.01 | 9.4 s |
| `eq,hue` / `color-adjust` | 0.92 s | 1.46 s | 0.63 | 1.21 s | 1.54 s | 0.79 | 0.7 s |
| `vignette` / `vignette` | 3.49 s | 1.51 s | 2.31 | 3.59 s | 1.59 s | 2.26 | 3.1 s |
| `bilateral` / 17×17 bilateral | 2.74 s | 4.04 s | 0.68 | 2.85 s | 4.08 s | 0.70 | 22.5 s |
| `xfade` dissolve / `dissolve` | 5.88 s | 1.83 s | **3.21** | 6.24 s | 2.39 s | 2.61 | 54.2 s |
| `xfade` pixelize / `pixelize-transition` | 4.15 s | 1.78 s | 2.33 | 4.67 s | 2.28 s | 2.05 | 30.8 s |
| `xfade` circleopen / `circle-reveal` | 5.19 s | 1.78 s | 2.92 | 5.37 s | 2.22 s | 2.42 | 51.3 s |
| `xfade` zoomin / `zoom-transition` | 3.71 s | 1.81 s | 2.05 | 3.96 s | 2.26 s | 1.75 | 21.4 s |

× = CPU wall / gpufx wall. The gpufx processes use under 1 s of CPU time on raw input (about 7 s with H.264,
which is the decoder); RAM is about 0.42 GB for gpufx against 0.1–0.37 GB on the CPU.

**Joining six clips with five transitions** (same setup as the section above, only the transition changed;
chain = 5 `gpufx` with `enable`/`bypass=auto`, graph = one `gpufx` with inline `enable`/`bypass`):

| Transition | CPU `xfade` | gpufx chain | gpufx graph | CPU utime / gpufx utime | maxrss CPU / gpufx |
|---|---|---|---|---|---|
| dissolve | 3.82 s (432 fps) | 3.32 s (497 fps) | **2.72 s** (607 fps) | 37.1 s / 14.9 s | 1578 / 825 MB |
| pixelize | 3.42 s (482 fps) | **2.56 s** (645 fps) | 2.58 s (640 fps) | 33.1 s / 13.1 s | 1595 / 824 MB |

**Stacked chain**: on each of two inputs Gaussian blur (σ 3) + sharpen + color, then a circle transition over
the whole 30 s, then a vignette. CPU: `[0]gblur=sigma=3,unsharp=3:3:0.8:3:3:0.8,eq=...,hue=h=20[a]; [1]...[b];
[a][b]xfade=transition=circleopen:duration=30:offset=0,vignette`. gpufx: one `gpufx` with an 8-node graph
`[0]gaussian-blur[a0]; [a0]sharpen[a1]; [a1]color-adjust[a2]; [1]...[b2]; [a2][b2]circle-reveal[t]; [t]vignette[out]`.
4K: both clips scaled to 3840×2160 and encoded again with H.264 (CRF 14), 900 frames each.

| Source | CPU | gpufx graph | × | CPU utime / gpufx utime | maxrss CPU / gpufx |
|---|---|---|---|---|---|
| 1080p raw | 22.90 s (39 fps) | 2.48 s (362 fps) | **9.2** | 93.4 s / 0.8 s | 527 / 471 MB |
| 1080p H.264 | 23.27 s (39 fps) | 2.63 s (342 fps) | 8.8 | 102.5 s / 12.7 s | 829 / 673 MB |
| 4K H.264 (decode only: 2.64 s) | 87.16 s (10 fps) | 8.85 s (102 fps) | **9.8** | 395.5 s / 41.9 s | 3044 / 1761 MB |

**Correctness** (frame 150, CPU against gpufx; transitions with `duration=10`, so progress 0.5): the effects do
not compute the same thing, so this is a rough check plus a look at the frames side by side. PSNR: bilateral
41.3 dB, small blur 39.6 dB, sharpen 36.0 dB, large blur 34.1 dB, vignette 30.5 dB (other falloff curve),
color 20.3 dB (other hue model); the transitions differ by design (`xfade` circleopen is a wide soft gradient,
`circle-reveal` a sharp circle; `xfade` zoomin shows a different moment) and the random ones use other
patterns. The raw yuv files carry no color tags: `gpufx` then reads them with another matrix/range (an
upload/download round trip falls to 25 dB), so for the check they were tagged with
`setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709` (round trip 41.9 dB, the same as the
H.264 clips). The timing runs used the untagged files; the work done per frame is the same.

What the numbers say:

- One cheap filter does not pay for the trip to the GPU: upload + download alone take 1.42 s for 900 frames
  (635 fps), more than `eq,hue`, `unsharp` or `gblur` σ 24 on 32 threads. `gblur` is an IIR filter whose cost
  does not grow with σ, while `gaussian-blur` 48 runs 97 taps per pass; the 17×17 bilateral (289 taps) is
  slower than FFmpeg's O(1) `bilateral` for the same reason. GPU wins where the CPU filter is slow per pixel:
  `vignette` 2.3×, `gblur` σ 3 1.9×.
- Full-length transitions are 2–3.2× faster on gpufx and use almost no CPU (`xfade` takes 21–54 s of CPU time
  for 900 frames).
- In the six-clip join the transitions cover only 155 of 1650 frames, so the gain stays at 1.15–1.4× (decode
  bound), as with fade.
- Stacking filters is where the GPU pays: the 8-effect graph is 9–10× faster at 1080p and 4K. The frames go up
  and down once, all steps run on the GPU, and the CPU only decodes. At 4K the CPU path runs at 10 fps.
