Tiếng Việt: [README-vi.md](README-vi.md)

# FFmpegGpuFilter (gpufx)

Video effects powered by **GPU shaders** for FFmpeg, loaded from external **`.zip` packages**
(CapCut style). FFmpeg is built once with the `gpufx` filter; a new effect is just a new zip package.

- **WGSL** or **GLSL** shaders, multiple passes, multiple inputs, bundled textures, auto-generated parameters.
- Runs on **Vulkan, DirectX 12, Metal, OpenGL** (via [wgpu](https://wgpu.rs)), on Windows/Linux/macOS.
- Parameters are literals or time-based expressions; change them at run time with `sendcmd`.
- Several effects in one filter (`effect='blur.zip|vignette.zip'`): the frame is uploaded to the
  GPU once, runs through the whole chain, and only then goes back to RAM.
- A package declares **input/output rules** (pixel format, size, same size across inputs);
  a stream that does not match gets a clear error instead of a silent conversion.
- 36 sample effects: color adjustment, grayscale, sepia, sharpen, pixelate, chroma key,
  picture-in-picture, fitting a picture over a blurred background, falling maple / ginkgo leaves (PNG images in the package), transitions (crossfade, slide, wipe, circle, clock, collapse, expand,
  dip to black, dissolve, pixelize, zoom, blinds, checkerboard, push box, film strip, photo collection...)

```sh
ffmpeg -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect=wipe-transition.zip:params='progress=clip((t-1)/1.5\,0\,1)|angle=45'" out.mp4
```

Docs: [design](docs/DESIGN.md) · [package format and how to write shaders](docs/EFFECT_FORMAT.md)

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
  Visual filters (`drawtext`, `overlay`, `gblur`...) and hw filters (`hwupload`, `scale_cuda`...) are gone.
  If you need another filter, add its name to that file and rebuild.
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
