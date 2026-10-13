Tiếng Việt: [README-vi.md](README-vi.md)

# FFmpegGpuFilter (gpufx)

Video effects powered by **GPU shaders** for FFmpeg, loaded from external **`.zip` packages**
(CapCut style). FFmpeg is built once with the `gpufx` filter; a new effect is just a new zip package.

- **WGSL** or **GLSL** shaders, multiple passes, multiple inputs, bundled textures, auto-generated parameters.
- Runs on **Vulkan, DirectX 12, Metal, OpenGL** (via [wgpu](https://wgpu.rs)), on Windows/Linux/macOS.
- Parameters are literals or time-based expressions; change them at run time with `sendcmd`.
- Several effects in one filter (`effect='blur.zip|vignette.zip'`): the frame is uploaded to the
  GPU once, runs through the whole chain, and only then goes back to RAM.
- A whole **effect graph** in one filter (`graph='[0]split[a][b]; [a]blur.zip[x]; [x][b]crossfade.zip[out]'`):
  branches, several inputs and several outputs, all in one GPU submission; `split` copies nothing and
  intermediate textures are pooled.
- A package declares **input/output rules** (pixel format, size, same size across inputs);
  a stream that does not match gets a clear error instead of a silent conversion.
- 36 sample effects: color adjustment, grayscale, sepia, sharpen, pixelate, chroma key,
  picture-in-picture, fitting a picture over a blurred background, falling maple / ginkgo leaves (texture arrays with mipmaps, custom paths from expressions), transitions (crossfade, slide, wipe, circle, clock, collapse, expand,
  dip to black, dissolve, pixelize, zoom, blinds, checkerboard, push box, film strip, photo collection...)

- **Vulkan frames without copies**: `hwupload` frames (`AV_PIX_FMT_VULKAN`, one image per plane) are processed
  in place on FFmpeg's own Vulkan device, synchronised with its timeline semaphores; frames never go back
  to RAM between filters. Frames of the Vulkan decoders (`-hwaccel vulkan`) are multiplane images and are refused
  for now.
- **D3D12 and D3D11 frames** (Windows): `AV_PIX_FMT_D3D12` frames (`-init_hw_device d3d12va`) are processed in
  place on FFmpeg's own `ID3D12Device`, synchronised with their fences; `AV_PIX_FMT_D3D11` frames run on the D3D12
  device of the same adapter through shared NT handles (outputs without a copy, other inputs with one GPU copy).
  nv12 and p010le. Not yet run on GPU hardware (CI runs them on WARP).
- Optional on-disk shader cache: `GPUFX_SHADER_CACHE=<dir>` (Vulkan; see [design](docs/DESIGN.md)).

```sh
ffmpeg -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect=wipe-transition.zip:params='progress=clip((t-1)/1.5\,0\,1)|angle=45'" out.mp4
```

```sh
# one upload, a diamond of effects on the GPU, two output pads written to two files
ffmpeg -i a.mp4 -i b.mp4 -filter_complex \
  "[0:v][1:v]gpufx=graph='[0]split[a][b]; [a]gaussian-blur.zip[ba]; [b]grayscale.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[x]; [x]split[x1][x2]; [x2][1]wipe-transition.zip[w]':params='x.progress=0.5|w.progress=t'[mix][wipe]" \
  -map "[mix]" mix.mp4 -map "[wipe]" wipe.mp4
```

```sh
# Vulkan frames: upload once, every effect on FFmpeg's Vulkan device, download once
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=effect=vignette.zip,gpufx=effect=sepia.zip,hwdownload,format=nv12" out.mp4
```

```sh
# Faster transfers (Vulkan): gpufx_upload/gpufx_download pipeline the copies; out_format=rgba keeps
# separate gpufx filters in RGBA between them (the last one goes back to nv12)
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx=effect=vignette.zip:out_format=rgba,gpufx=effect=sepia.zip:out_format=nv12,gpufx_download,format=nv12" out.mp4
```

Docs: [design](docs/DESIGN.md) · [package format and how to write shaders](docs/EFFECT_FORMAT.md)

## Benchmark

Build `a4296b2` (win64 release package), measured on 2026-10-13.

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
| gpufx `crossfade.zip`, Vulkan | 5.47 s | 451 MB | 199 / 76 MB |
| gpufx `crossfade.zip`, DX12 | 7.26 s | 546 MB | 173 / 154 MB |
| gpufx `wipe-transition.zip`, Vulkan | 5.46 s | – | – |
| gpufx `circle-reveal.zip`, Vulkan | 5.53 s | 450 MB | 199 / 76 MB |

**A chain of effects**: clip A blur → color adjust → vignette, clip B sepia → sharpen → vignette, crossfade,
then sharpen. The CPU side uses `gblur`, `eq`, `vignette`, `colorchannelmixer`, `unsharp`, `xfade`.

| Filter | Time | Peak RAM | VRAM ded. / shared |
|---|---|---|---|
| CPU filters | 34.95 s | 655 MB | 0 |
| 8 separate `gpufx` filters | 29.06 s | 601 MB | 459 / 84 MB |
| one `gpufx=graph=...` | **7.13 s** | 536 MB | 203 / 82 MB |

**Vulkan frames and the transfer filters** (same machine, idle GPU, 2026-10-13, range of 3 runs; RAM is
the peak working set, VRAM the dedicated peak of the 3rd run). Transfers: clip A only, nv12, 90 s.

| Filter | Time | Peak RAM | VRAM ded. |
|---|---|---|---|
| Decode only (nv12) | 1.82–2.09 s | 261 MB | 16 MB |
| `hwupload,hwdownload` | 3.49–4.09 s | 280 MB | 26 MB |
| `gpufx_upload,hwdownload` | 3.27–4.11 s | 284 MB | 32 MB |
| `hwupload,gpufx_download` | 2.52–3.10 s | 297 MB | 35 MB |
| `gpufx_upload,gpufx_download` | 2.34–3.11 s | 291 MB | 32 MB |
| Chain, 8 separate `gpufx`, hwupload/hwdownload | 11.73–12.18 s | 578 MB | 578 MB |
| Chain, 8 separate `gpufx`, gpufx_upload/download | 10.23–10.31 s | 617 MB | 578 MB |
| Chain, 8 separate, `out_format=rgba`, hwupload/hwdownload | 10.31–11.18 s | 612 MB | 679 MB |
| Chain, 8 separate, `out_format=rgba`, gpufx_upload/download | 8.51–9.12 s | 590 MB | 681 MB |
| Chain, one `graph=`, hwupload/hwdownload | 8.54–9.13 s | 577 MB | 257 MB |
| Chain, one `graph=`, gpufx_upload/download | **6.25–6.53 s** | 545 MB | 260 MB |

`gpufx_download` removes most of the readback cost (`hwdownload` waits for every copy); the upload side
gains little since `hwupload` does not wait either.

What the numbers say:

- With frames in system memory each `gpufx` instance costs about 1.5 ms per frame whatever the shader does:
  upload, YUV → RGBA on the GPU, readback and the wait for the GPU. The pixel format conversion runs in a shader,
  FFmpeg inserts no `scale` filter. A light transition alone is therefore slower than `xfade` on a fast CPU.
- Put the whole chain in one `gpufx` (`graph=` or `effect='a.zip|b.zip'`): the frames cross the bus once and
  extra effects are nearly free (8 effects: 7.1 s against 5.5 s for one crossfade, about 5× faster than CPU).
- Starting a `gpufx` costs about 1 s (device creation and shader compilation), so short clips gain less.
- Not measured yet: Vulkan hw frames end to end (`-hwaccel vulkan` → gpufx → GPU encode), which skips the
  upload and readback.

## Build

You need Rust (stable) and a GPU driver (on Linux without a GPU you can use `mesa-vulkan-drivers`/lavapipe).

```sh
cargo build --release
cargo test --release                       # run the sample effects on the available GPU
./target/release/gpufx run examples/effects/vignette -i in.png -o out.png -p strength=0.9
scripts/pack-effects.sh                    # only package the effects: examples/effects -> dist/effects/*.zip
```

Adding or editing effects **does not require rebuilding FFmpeg**: run `scripts/pack-effects.sh`
(Windows: `scripts\pack-effects.ps1`) and use the new `.zip` file.

### Fast build on a prebuilt FFmpeg (recommended)

Take the prebuilt FFmpeg 9.0 shared build from
[tqk2811/FFmpegBuild](https://github.com/tqk2811/FFmpegBuild/releases), rebuild only
`libavfilter` (gpufx + a trimmed filter list) and swap it into the package. `ffmpeg`, `ffprobe` and
the remaining libraries (`avcodec`, `avformat`...) stay as they are in the prebuilt. It takes a few minutes:

```sh
scripts/build-prebuilt.sh            # linux64 -> dist/linux64
scripts/build-prebuilt.sh win64      # cross-compile with mingw-w64 -> dist/win64
scripts/test-bundle.sh dist/linux64  # run every effect through ffmpeg, including the error-reporting rules
```

You need cargo, gcc, make, pkg-config, curl and patchelf (win64 also needs `mingw-w64`, `unzip` and the Rust
target `x86_64-pc-windows-gnu`). Change the prebuilt with the variables `FFBUILD_TAG`,
`FFBUILD_VERSION` and `FFBUILD_LICENSE` (`lgpl`, `gpl`, `lgpl2`, `gpl2`).

`libavfilter` must be built from **exactly the same commit** as the prebuilt so the ABI matches the other
libraries. The `external/FFmpeg` submodule is pinned to that commit (`n9.0-2-g03d9533176`, branch
`release/9.0`); the script stops if the two differ. `ffmpeg` looks up filters by name at run time,
so it does not care how many filters `libavfilter` contains. A command that uses a removed filter is the
only one that reports `No such filter`.

Notes for this build:
- Only the filters in [docker/keep-filters.txt](docker/keep-filters.txt) remain, plus `gpufx`: plumbing
  (`scale`, `format`, `trim`, `split`, `sendcmd`...) and filters that normalise the inputs: timing, metadata, layout,
  deinterlacing and colour space (`fps`, `setpts`, `setsar`, `setdar`, `settb`, `setrange`, `setparams`, `pad`, `concat`,
  `select`, `loop`, `reverse`, `yadif`, `bwdif`, `colorspace`, `showinfo`) plus basic audio (`volume`, `amix`, `adelay`, `afade`, `atempo`...).
  `hwupload`, `hwdownload` and `hwmap` stay for Vulkan, D3D12 and D3D11 frames. Visual filters (`drawtext`, `overlay`, `gblur`...)
  and other hw filters (`scale_cuda`, `scale_vulkan`...) are gone. If you need another filter, add its name to that
  file and rebuild.
- Vulkan frames need Vulkan in the prebuilt `libavutil` (the FFmpegBuild releases have it) and the Khronos
  Vulkan-Headers, which the script clones (tag `v1.4.321`, or `VULKAN_HEADERS=<dir>`); without them the filter is
  built without Vulkan frames and says so.
- win64: D3D12/D3D11 frames need d3d12va/d3d11va in the prebuilt `libavutil` (the FFmpegBuild releases have them);
  libavfilter is configured with `--enable-d3d11va --enable-d3d12va`, with `d3d12video.h` of mingw-w64 v12.0.0
  fetched when the installed mingw-w64 lacks it.
- `ffmpeg` prints `WARNING: library configuration mismatch` in the banner (or when you drop
  `-hide_banner`), because `libavfilter` is configured differently from the other libraries. The warning is harmless.
- `lib/pkgconfig/libavfilter.pc`, the headers and the import lib still come from the prebuilt (they know nothing
  about gpufx). The package is for running `ffmpeg`, not for linking other programs against `libavfilter`.
- win64: `avfilter-12.dll` and `gpufx.dll` use `msvcrt.dll`, while the prebuilt DLLs use UCRT.
  FFmpeg allocates and frees memory through `avutil`, so this works; CI tests it on Windows.

### Full FFmpeg build from source (Docker)

Builds all of FFmpeg from the `external/FFmpeg` submodule (the same 9.0 commit as above), which is much slower.
The script builds in Docker in the style of
[BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds); you only need Docker and git:

```sh
./build.sh            # linux64
./build.sh win64      # cross-compile for Windows with mingw-w64
./build.sh all
```

On Windows (Docker Desktop): `.\build.ps1` (defaults to win64).

The result is in `dist/<target>/`:

```
bin/      ffmpeg, ffprobe, libgpufx.so | gpufx.dll, gpufx-cli
effects/  the sample effects packaged as .zip
include/  gpufx.h
```

This build **disables all of FFmpeg's built-in video filters** (overlay, drawtext, gblur...).
Video effects come from `gpufx` packages. Audio filters are kept, and a few minimal video filters that the
ffmpeg CLI or gpufx need are kept too (`scale`, `format`, `trim`, `split`,
`sendcmd`...). The list is in [docker/keep-filters.txt](docker/keep-filters.txt); edit that file
to add or remove filters. Codecs use FFmpeg's built-in set; external libraries such as x264 are not included yet.

Later builds are faster for the Rust part thanks to the Docker volumes `gpufx-work-<target>` and `gpufx-cargo-registry`; FFmpeg is rebuilt from scratch every time to keep it clean.

### Integrating into another FFmpeg tree yourself

```sh
scripts/install-libgpufx.sh "$HOME/.local/gpufx"          # libgpufx + gpufx.h + gpufx.pc
ffmpeg/integrate.sh /path/to/FFmpeg                       # adds vf_gpufx.c, patches configure
cd /path/to/FFmpeg
PKG_CONFIG_PATH="$HOME/.local/gpufx/lib/pkgconfig" ./configure --enable-libgpufx
make -j"$(nproc)"
```

## Layout

| Directory | Contents |
|-----------|----------|
| `crates/gpufx-core` | Engine: reads packages and manifests, handles parameters, compiles and runs shaders |
| `crates/gpufx-ffi` | `libgpufx` with a C ABI (`include/gpufx.h`) |
| `crates/gpufx-cli` | The `gpufx info / check / pack / run` command |
| `ffmpeg/` | The `vf_gpufx.c` filter and the integration script |
| `external/FFmpeg` | FFmpeg source submodule |
| `docker/`, `build.sh`, `build.ps1` | Build FFmpeg + gpufx with one command in Docker |
| `examples/effects/` | 36 sample effects |
| `scripts/` | `build-prebuilt.sh` (fast build on a prebuilt FFmpeg), `test-bundle.sh`, `install-libgpufx.sh`, `pack-effects.sh`/`.ps1` (zip packaging) |

## License

The repo's source code is under the [MIT](LICENSE) license, except for the following:

| Part | License |
|------|---------|
| `ffmpeg/vf_gpufx.c` (the filter, built into `libavfilter`) | LGPL 2.1 or later, same as FFmpeg |
| `external/FFmpeg` (submodule) and the FFmpeg libraries in the build | FFmpeg's license: `scripts/build-prebuilt.sh` defaults to LGPL v3 (`lgpl`), `lgpl2` is LGPL 2.1; the Docker build (`build.sh`) is LGPL 2.1 or later; the `gpl`/`gpl2` builds use GPL. The actual license is the `LICENSE.txt`/`FFMPEG-LICENSE.txt` file shipped with the build |
| Leaf images of `falling-maple` | Apache 2.0 (Noto Emoji, Google) |
| Leaf images of `falling-ginkgo` | CC BY 3.0 (game-icons.net, Delapouite) |
| `bin/dxcompiler.dll` in the win64 build (DirectX Shader Compiler, Microsoft) | LLVM (University of Illinois/NCSA), MIT and the Microsoft DXC terms: `bin/LICENSE-dxcompiler-*.txt`. A separate DLL that wgpu loads at run time; delete it to compile with FXC |

The sources and licenses of the leaf images are in [assets/leaves/README.md](assets/leaves/README.md).

The `libgpufx` library and the sample effects can be used in closed-source software, but you must include
the copyright notices: the repo's MIT, Apache 2.0 / CC BY 3.0 if you use the two leaf effects, and the licenses
of the Rust crates that `libgpufx` links against.

When you distribute a build that includes FFmpeg, you must comply with FFmpeg's license: include the license text
and copyright notices, let users replace the libraries (the build uses shared libraries), and
provide the FFmpeg source you used, including `vf_gpufx.c` and `ffmpeg/integrate.sh`. For the `gpl`/`gpl2` builds,
all of FFmpeg in the build is GPL. See also https://ffmpeg.org/legal.html (this is not
legal advice).
