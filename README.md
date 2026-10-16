Tiếng Việt: [README-vi.md](README-vi.md)

# FFmpegGpuFilter (gpufx)

Video effects powered by **GPU shaders** for FFmpeg, loaded from external **`.zip` packages**
(CapCut style). FFmpeg is built once with the `gpufx` filter; a new effect is just a new zip package.

- **WGSL** or **GLSL** shaders, multiple passes, multiple inputs, bundled textures, auto-generated parameters.
- The FFmpeg filter runs on **Vulkan, Direct3D 12, Direct3D 11** and **Metal** (macOS) frames (via
  [wgpu](https://wgpu.rs)), on Windows/Linux/macOS. OpenGL is not supported.
- Parameters are literals or time-based expressions; change them at run time with `sendcmd`.
- Several effects in one filter (`effect='blur.zip|vignette.zip'`): the whole chain runs in one GPU
  submission, without intermediate frames.
- A whole **effect graph** in one filter (`graph='[0]split[a][b]; [a]blur.zip[x]; [x][b]crossfade.zip[out]'`):
  branches, several inputs and several outputs, all in one GPU submission; `split` copies nothing and
  intermediate textures are pooled.
- A package declares **input/output rules** (pixel format, size, same size across inputs);
  a stream that does not match gets a clear error instead of a silent conversion.
- 36 sample effects: color adjustment, grayscale, sepia, sharpen, pixelate, chroma key,
  picture-in-picture, fitting a picture over a blurred background, falling maple / ginkgo leaves (texture arrays with mipmaps, custom paths from expressions), transitions (crossfade, slide, wipe, circle, clock, collapse, expand,
  dip to black, dissolve, pixelize, zoom, blinds, checkerboard, push box, film strip, photo collection, sliding bars, spin...)

- **Vulkan frames without copies**: `hwupload` frames (`AV_PIX_FMT_VULKAN`, one image per plane) are processed
  in place on FFmpeg's own Vulkan device, synchronised with its timeline semaphores; frames never go back
  to RAM between filters. Frames of the Vulkan decoders (`-hwaccel vulkan`) are multiplane images and are refused
  for now.
- **D3D12 and D3D11 frames** (Windows): `AV_PIX_FMT_D3D12` frames (`-init_hw_device d3d12va`) are processed in
  place on FFmpeg's own `ID3D12Device`, synchronised with their fences; `AV_PIX_FMT_D3D11` frames run on the D3D12
  device of the same adapter through shared NT handles (outputs without a copy, other inputs with one GPU copy).
  nv12 and p010le. Tested on NVIDIA RTX 4060 Laptop and Intel UHD Graphics (Windows 11); CI only builds them.
- Optional on-disk shader cache: `GPUFX_SHADER_CACHE=<dir>` (Vulkan pipeline cache; D3D12 DXIL when
  `dxcompiler.dll` is on the DLL search path). `gpufx pack --precompile` puts D3D12 shaders in a package, used only
  with `GPUFX_TRUST_PRECOMPILED=1` (see [design](docs/DESIGN.md)).

```sh
# gpufx outputs GPU frames: give it a device (it uploads software inputs itself) and
# download before the encoder
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='wipe-transition.zip=progress=clip((t-1)/1.5\,0\,1)&angle=45',hwdownload,format=yuv420p" out.mp4
```

```sh
# a diamond of effects on the GPU, two output pads written to two files
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0:v][1:v]gpufx=graph='[0]split[a][b]; [a]gaussian-blur.zip[ba]; [b]grayscale.zip|vignette.zip[gb]; [ba][gb]crossfade.zip=progress=0.5[x]; [x]split[x1][x2]; [x2][1]wipe-transition.zip=progress=t[w]'[mix][wipe];[mix]hwdownload,format=yuv420p[m];[wipe]hwdownload,format=yuv420p[w2]" \
  -map "[m]" mix.mp4 -map "[w2]" wipe.mp4
```

Parameters are written **inline**, right after the package name, like the options of a native FFmpeg filter:
`pkg.zip=key=value:key2=value2`. This works in `effect=` (also in a chain: `effect='a.zip=k=1|b.zip'`) and in
every node of `graph=`. Keys are named, a value is a constant or an expression (`t`, `n`, `w`, `h`, `a`, `sar`,
`dar`), and two keys are reserved for the effect instance: `enable=<expr>` switches that effect on and off per
frame and `bypass=0|auto` picks the input it copies while off. They are separate from the filter's own timeline
`enable=` and `bypass=` options, which stay outside the effect string. An unknown key, a key given twice or a
`bypass` other than `0`/`auto` is an error that names the effect and the key.

- Put the whole `effect=`/`graph=` value in `'...'`. FFmpeg splits filter options at `:` *after* it removes
  those quotes, so separate inline keys with `&` (`effect='x.zip=a=1&b=2'`, no escaping needed at the FFmpeg
  level). The FFmpeg-style `:` also works but must be written `\:` there (`effect='x.zip=a=1\:b=2'`); a single
  key needs no separator. Commas in expressions are escaped `\,` as for any filter option.
- Inside the effect string, `\` escapes one of `\ ' : & ; | = [ ]` (`\&` is a literal `&` in a value; before any other character it stays literal, so
  Windows paths work) and `'...'` quotes a value.
- A `color` value is `#RRGGBB` or `#RRGGBBAA` (alpha defaults to `ff`), or 3 or 4 numbers from 0 to 1. Whether the
  alpha is used depends on the effect: its README says, per parameter, if alpha is ignored, sets a strength, or is
  written to the output.
- `sendcmd` is a runtime command, not a filter option: `sendcmd=c='0.5 gpufx@g params gb.strength=0.2'` sets
  `node.name=value` pairs (separated by `|`) while the stream runs; see [design](docs/DESIGN.md).

```sh
# a chain: the first gpufx uploads, every effect runs on FFmpeg's Vulkan device, one download
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx=effect=vignette.zip,gpufx=effect=sepia.zip,hwdownload,format=nv12" out.mp4
# D3D12 (Windows): the same with -init_hw_device d3d12va=dx -filter_hw_device dx
```

```sh
# Faster transfers (Vulkan): gpufx_upload/gpufx_download pipeline the copies; out_format=rgba keeps
# separate gpufx filters in RGBA between them (the last one goes back to nv12)
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx=effect=vignette.zip:out_format=rgba,gpufx=effect=sepia.zip:out_format=nv12,gpufx_download,format=nv12" out.mp4
```

Like FFmpeg's `*_cuda` filters, `gpufx` outputs **GPU frames only** (Vulkan, D3D12, D3D11, or VideoToolbox on macOS). Inputs may be GPU
frames (`hwupload`, `gpufx_upload`, another `gpufx`) or software frames, which `gpufx` uploads itself on the device
of its GPU inputs or, when none is on the GPU, on `-filter_hw_device`; without a device it stops and says which
options to add. Put `hwdownload,format=<fmt>` or `gpufx_download,format=<fmt>` before CPU filters and encoders
(`<fmt>` is the output's format, by default the input's when the effect may output it). A chain of `gpufx`
filters therefore uploads each frame once and reads it back once. Fastest first:

1. one `gpufx=graph=...` with every effect;
2. separate filters between `gpufx_upload` and `gpufx_download`, `out_format=rgba` on all but the last;
3. separate filters behind one upload (by the first `gpufx` or `hwupload`), then `hwdownload`.

**Limitation: no alpha with D3D12 and D3D11 frames.** FFmpeg makes D3D12 frames of `nv12` and `p010le` only
(D3D11: no `rgba` either), so `hwdownload` gives one of those, an output with alpha loses it there, and
`out_format=rgba`, `yuva420p` or `yuva444p` fails (`Unsupported pixel format: rgba`).
Vulkan keeps alpha with `out_format=rgba`. On D3D, split the result and send one copy through [alpha-extract](examples/effects/ffmpeg/alpha-extract/README.md) to get the alpha as a gray picture, then
join both on the CPU with `alphamerge`.

Intel GPUs on Windows with FFmpeg 9: `hwupload` (and `hwdownload` of `hwupload` frames) fails to allocate or
corrupts the picture through the driver's host image copy; use `gpufx_upload` / `gpufx_download`, or open the
device with `disable_multiplane=1,linear_images=1`. `gpufx` refuses such frames. See [docs/INTEL_VULKAN.md](docs/INTEL_VULKAN.md).

The filter's `backend` option is for testing only (leave it at `auto`, which follows the frames); it refuses
`backend=metal` except on macOS (the library and the `gpufx` CLI still take it). On macOS the filter works on VideoToolbox frames (nv12, p010le) through Metal, e.g.
`-init_hw_device videotoolbox=vt -filter_hw_device vt -vf "gpufx=effect=vignette.zip,hwdownload,format=nv12"`;
this path has not run on a Mac yet (see below).

Docs: [design](docs/DESIGN.md) · [package format and how to write shaders](docs/EFFECT_FORMAT.md) · [benchmark](docs/BENCHMARK.md)

## Hardware and OS requirements

- **Windows**: Windows 10 64-bit or later. D3D12: feature level 11_0, resource binding tier 2 (NVIDIA Kepler+,
  AMD GCN+, Intel Skylake+). D3D11 frames: Windows 10 1703+ (D3D11.4 shared fences).
- **Linux**: Vulkan 1.1+ with a graphics + compute queue and timeline semaphores (FFmpeg 9 asks for 1.3);
  NVIDIA proprietary, Mesa RADV/ANV, lavapipe (CPU). The linux64 bundle needs glibc 2.35+ (Ubuntu 22.04).
- **macOS**: Metal; VideoToolbox frames need Apple silicon (nv12/p010le). Untested on a Mac.
- Intel GPU on Windows with FFmpeg 9 Vulkan frames: see [Intel Vulkan](docs/INTEL_VULKAN.md).

Details, sources and known issues: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).

## Build

You need Rust (stable) and a GPU driver (on Linux without a GPU you can use `mesa-vulkan-drivers`/lavapipe).

```sh
cargo build --release
cargo test --release                       # run the sample effects on the available GPU
./target/release/gpufx run 'examples/effects/ffmpeg/vignette=strength=0.9' -i in.png -o out.png
scripts/pack-effects.sh                    # only package the effects: examples/effects -> dist/effects/*.zip
```

Adding or editing effects **does not require rebuilding FFmpeg**: run `scripts/pack-effects.sh`
(Windows: `scripts\pack-effects.ps1`) and use the new `.zip` file.

### Tests

GPU tests skip themselves (with a `skipping: ...` line) when no adapter fits, so a green run can hide
skipped checks: add `-- --nocapture` to see them.

- `GPUFX_TEST_BACKEND=vulkan|dx12|metal` pins the backend (default: the best one). On Windows run the
  suite once with `vulkan` and once with `dx12`.
- The D3D12 shader cache tests need `dxcompiler.dll` on `PATH`; without it they skip. Fetch it with
  `scripts/fetch-dxc.sh build/dxc` and put `build/dxc` on `PATH`.
- CI runs the suite on lavapipe (Linux, Vulkan) and Metal (macOS). On Windows it only runs fmt and clippy:
  WARP, the only adapter of hosted runners, runs shaders on the CPU and takes many minutes, so the D3D12
  tests run on a local GPU instead. Metal may round a YUV sample one step away from
  the CPU path, which the YUV tests allow on Metal only.

### What has not been tested

- **macOS**: no Mac device; only `cargo test` on the CI macOS runner (Metal). The VideoToolbox frame path of the
  filter is only compiled (cross-checked from Windows); the CI job `ffmpeg-macos` builds FFmpeg with it and runs
  `test-bundle.sh`, but it has not run yet, and a hosted runner may have no usable Metal adapter (then the
  tests are skipped with a warning). There is no macOS bundle to download.
- **Linux on a real GPU**: Linux only runs on lavapipe (software Vulkan), in CI and in a VM. Vulkan frames
  shared with FFmpeg have been run on real GPUs only on Windows.
- **OpenGL**: not built in. It cannot share frames with FFmpeg and has no R8/R16 storage textures for YUV planes.

### Fast build on a prebuilt FFmpeg (recommended)

Take the prebuilt FFmpeg 9.0 shared build from
[tqk2811/FFmpegBuild](https://github.com/tqk2811/FFmpegBuild/releases), rebuild only
`libavfilter` (gpufx + every FFmpeg filter that builds without extra libraries) and swap it into the package. `ffmpeg`, `ffprobe` and
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
so it does not care how many filters `libavfilter` contains. A command that uses a missing filter is the
only one that reports `No such filter`.

Notes for this build:
- Every FFmpeg filter is built by default (`FFMPEG_FILTERS=all`), plus `gpufx`: `overlay`, `xfade`, `alphaextract`,
  `alphamerge`, `testsrc2`, `color`... (win64: 440 filters instead of 62, the `avfilter` dll grows from 1.2 MB to
  6 MB, the build takes about one minute longer). The prebuilt build rebuilds only `libavfilter`, with
  `--disable-autodetect`, without `avcodec`/`avformat`, and under LGPL by default, so some filters are still
  missing: those that need `avcodec`/`avformat`, external libraries (`drawtext` with freetype, `zscale`,
  `subtitles`...) or GPL (`boxblur`...). For a small build use `FFMPEG_FILTERS=keep`: only the list in
  [docker/keep-filters.txt](docker/keep-filters.txt) remains, plus `gpufx` (plumbing such as `scale`, `format`,
  `trim`, `split`, `sendcmd`; input normalisers such as `fps`, `setpts`, `pad`, `concat`, `yadif`, `colorspace`;
  basic audio; `hwupload`, `hwdownload`, `hwmap`). To keep another filter there, add its name to that file and
  rebuild.
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

This build enables **every FFmpeg filter** by default (`FFMPEG_FILTERS=all`), so `overlay`, `xfade`, `gblur`...
are there next to the `gpufx` effects. `FFMPEG_FILTERS=keep` restores the short list in
[docker/keep-filters.txt](docker/keep-filters.txt) plus every audio filter; edit that file
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
| `examples/effects/` | 38 sample effects in `ffmpeg/`, `slideshow/` and `standalone/` groups |
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
of the Rust crates that `libgpufx` links against (`THIRD-PARTY-LICENSES-gpufx.txt` in the build, made with `cargo about`;
CI checks the crate licenses with `cargo deny check licenses`, see `deny.toml`).

When you distribute a build that includes FFmpeg, you must comply with FFmpeg's license: include the license text
and copyright notices, let users replace the libraries (the build uses shared libraries), and
provide the FFmpeg source you used, including `vf_gpufx.c` and `ffmpeg/integrate.sh`. For the `gpl`/`gpl2` builds,
all of FFmpeg in the build is GPL. See also https://ffmpeg.org/legal.html (this is not
legal advice).
