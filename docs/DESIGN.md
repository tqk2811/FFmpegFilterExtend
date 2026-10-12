Tiếng Việt: [DESIGN-vi.md](DESIGN-vi.md)

# Design: FFmpegGpuFilter (gpufx)

> Goal: run video effects as **GPU shaders** inside FFmpeg's `filter_graph`, with effects
> **loaded from external `.zip` packages** (CapCut style). Adding a new effect does not
> require rebuilding FFmpeg: you just supply the zip package and its parameters, and wire up the inputs/outputs in the graph.

## 1. Requirements

| # | Requirement | How it is met |
|---|-------------|---------------|
| R1 | **Shaders come first** (the reason to use a GPU) | Each effect *is* a chain of compute shaders. WGSL and GLSL are supported from the first version, with shader error checking that reports line numbers, multiple passes, bundled textures, and parameters generated automatically as `uniform`s |
| R2 | Multiple operating systems | Windows, Linux, macOS (Android/iOS later) |
| R3 | Multiple hardware / APIs | Vulkan, DirectX 12, Metal, OpenGL through **wgpu**; CUDA/D3D11/VAAPI through interop (phase 2) |
| R4 | Effects loaded externally, no FFmpeg rebuild | A single `gpufx` filter built **once**; effects are zip packages |
| R5 | Use Rust or C/C++ | The engine is written in **Rust**; the glue into FFmpeg is one small C file |

## 2. Architecture overview

```
 ffmpeg -vf "gpufx=effect=vignette.zip:params='strength=0.8'"
            │
            ▼
 ┌────────────────────────────┐   C ABI (gpufx.h)    ┌──────────────────────────────────┐
 │ libavfilter/vf_gpufx.c     │ ───────────────────▶ │ libgpufx (Rust, crates/gpufx-ffi) │
 │  - option effect/params    │                      │  gpufx-core:                      │
 │  - dynamic input pads from │                      │   package  : read zip / directory │
 │    the manifest (1..N      │                      │   manifest : schema, validation   │
 │    inputs)                 │                      │   params   : uniform layout       │
 │  - framesync, many inputs  │                      │   runtime  : compile shaders,     │
 │  - expressions in t, n     │                      │              run passes on wgpu   │
 │  - sendcmd / timeline      │                      │                                   │
 └────────────────────────────┘                      └───────────────┬──────────────────┘
                                                                     │ wgpu
                                         ┌────────────┬──────────────┼─────────────┬────────┐
                                         ▼            ▼              ▼             ▼        ▼
                                      Vulkan      DirectX 12       Metal        OpenGL   (WebGPU)
```

**Why only one filter?** FFmpeg has no run-time filter plugin mechanism: every filter must be
compiled into `libavfilter`. So we add *one* generic `gpufx` filter (patched in once,
see `ffmpeg/integrate.sh`), and all the effect logic lives in the shaders of the zip package. This
is exactly the CapCut model: the app is fixed, and effects are downloaded data.

**Why Rust + wgpu?**
- wgpu is a mature GPU abstraction layer that runs Vulkan/DX12/Metal/GL from the same source.
- It comes with **naga**, a pure-Rust shader compiler that reads WGSL, GLSL and SPIR-V and translates to
  SPIR-V/HLSL/MSL/GLSL for each backend. This is the most important part for R1: the author writes a
  shader **once** and it runs on every API.
- Rust is memory-safe when reading untrusted zip packages, and it exports a stable C ABI for FFmpeg.

Alternatives considered and rejected:

| Alternative | Why it was not chosen as the core |
|-------------|-----------------------------------|
| Vulkan + SPIR-V directly (like `libplacebo`) | Does not run natively on macOS/DX; we would have to rewrite what wgpu already provides |
| Write separate CUDA/DX/Vulkan code for each effect | Violates R4: every effect × every API |
| OpenCL (`vf_program_opencl`) | Uneven driver quality, absent on recent macOS, not a graphics shader |
| Plug into `libplacebo` custom shaders | Vulkan only, mpv hook syntax, no support for multiple inputs |

## 3. Effect package (`.zip`)

```
vignette.zip
├── manifest.json        required
├── shaders/*.wgsl|*.comp|*.glsl
└── textures/*.png       optional (LUT, mask, overlay)
```

Details of the format and how to write shaders: [EFFECT_FORMAT.md](EFFECT_FORMAT.md).

`manifest.json` summary:

```json
{
  "api": 1,
  "id": "io.github.tqk2811.gaussian-blur",
  "name": "Gaussian Blur",
  "inputs": [{ "name": "src" }],
  "params": [{ "name": "radius", "type": "float", "default": 6, "min": 0, "max": 48 }],
  "passes": [
    { "shader": "shaders/blur_h.wgsl", "inputs": ["src"], "output": "tmp" },
    { "shader": "shaders/blur_v.wgsl", "inputs": ["tmp"], "output": "out" }
  ]
}
```

- `inputs` determines the number of input pads on the filter (a transition uses 2 inputs, etc.).
- `params` are **generated automatically** by the runtime into a `params` struct in the shader, following the
  WGSL/std140 uniform alignment rules; the author just uses `params.radius`.
- `passes` run sequentially; the output of one pass is a readable texture in the next; the last pass is the
  final output.

## 4. Shader model (the core)

Each pass is a **compute shader**. Before the author's code, the runtime inserts an auto-generated
*prelude* (like Shadertoy providing `iResolution`, `iTime`):

| Binding | Name in the shader | Meaning |
|---------|--------------------|---------|
| 0 | `globals.size`, `globals.time`, `globals.frame`, `globals.time_int`, `globals.time_frac`, `globals.pixel_aspect` | Output size (px), time (seconds, f32), frame number, exact time (whole seconds + fraction), pixel aspect ratio (SAR) |
| 1 | `params.<name>` | Parameters from the manifest |
| 2 | `out_tex` | Texture the result is written to (`rgba8unorm`, or `rgba16float` when a frame of the chain has more than 8 bits) |
| 3 | `smp` | Linear sampler, clamp |
| 4.. | input/texture/pass names | Textures to read (`texture_2d<f32>`) |

Helper functions `gpufx_in_bounds(id)`, `gpufx_uv(id)`, `gpufx_write(id, color)` are included.

Why compute instead of fragment shaders: no render pass or vertex buffer is needed, multiple
passes are easy, reads and writes are unrestricted (separable blur, histogram, reduce), and it maps directly onto CUDA/Metal
compute when needed.

Shader languages:

| Language | Status | Notes |
|----------|--------|-------|
| WGSL | ✅ prototype | The standard WebGPU language, with the clearest errors |
| GLSL 450 (compute) | ✅ prototype | Convenient for porting existing shaders (GL Transitions, Shadertoy) |
| SPIR-V (precompiled) | Planned | Lets authors use HLSL/Slang → SPIR-V with external tools |
| HLSL / Slang | Planned | Compiled to SPIR-V/WGSL in `gpufx pack` |
| Shadertoy-style fragment shader (`mainImage`) | Planned | Wrapped into a compute shader automatically |

Shaders are checked before running: naga parses and validates them, and errors come back with the file name and
the position in the code (try `gpufx check <package>`). The FFmpeg filter prints that error through `av_log` and refuses to
initialize the graph instead of running incorrectly.

## 5. The `gpufx` FFmpeg filter

```
gpufx=effect=<zip|directory>[|<zip>...][:params='a=1|b=#ff0000|c=clip(t/2\,0\,1)'][:backend=auto|vulkan|dx12|metal|gl][:shortest=0|1]
gpufx=graph='[0]split[a][b]; [a]x.zip[c]; [c][b]y.zip[out]'[:params=...][:backend=...][:shortest=0|1]
```

- **effect**: path to the package. The filter's number of inputs comes from the manifest.
- **Effect chain** `effect='a.zip|b.zip|c.zip'`: runs one after another like three chained filters, but
  the frame is uploaded only once, all passes fit in a single GPU submit, and there is only one readback.
  The filter's inputs are the inputs of the first effect; only the first effect may have multiple inputs. The output
  follows the rules of the last effect. The rules of the later effects are checked as when chaining filters:
  the format is the first one in the previous effect's `output.formats` that the next effect accepts,
  and the size is the size of the first input. The frame stays RGBA on the GPU and is not converted to that format.
  Parameters are set as `package.name` (the file name without `.zip`, for example `vignette.strength`), `index.name`
  (counted from 0, required when two packages share a name or a package name is a number), or the bare name if only one
  effect has it. Spaces around `|` are ignored.
- **graph**: a whole effect graph with several inputs and outputs, in place of `effect`; see
  "GPU graph inside one filter" in section 6.
- **params**: `name=value` separated by `|`. A value is a literal (`0.5`, `1,0,0`, `#ff8800`)
  or an **FFmpeg expression** in `t`, `n`, `w`, `h`, `a` (`w/h`), `sar`, `dar` (`a*sar`),
  re-evaluated for every frame. This is how you do keyframes/transitions without external tools.
- **sendcmd / zmq**: the `params` command changes values at run time, for example
  `sendcmd=c='2.0 gpufx@fx params strength=0.2'`.
- **timeline** (`enable='between(t,1,3)'`) is supported.
- Multiple inputs use `framesync`: the first input decides the length and frame rate (an input with a
  different fps has its frames repeated or dropped). Another input that has not started yet is a transparent image; one that has
  ended holds its last frame (or use `shortest=1`).
- The output takes the size, SAR and frame rate of the first input (in a graph, of the input pad its source comes from); colorspace/range/alpha are the values
  negotiated on the output link. Color-dependent side data (HDR metadata, film grain...), motion
  vectors and video enc params are dropped because the pixels have changed.
- If an input's size or pixel format changes midstream, that is an error (`ffmpeg` rebuilds the
  graph itself, so you only hit this when using libavfilter directly).
- Warnings (non-blocking): different SARs across inputs, inputs above 10 bits (effects work in half
  float, about 11 bits), HDR PQ/HLG inputs (the shader treats them as SDR), interlaced inputs (the shader
  sees two fields as one frame). Shaders work with straight alpha: libgpufx divides premultiplied inputs
  (EXR, JPEG XL...) by alpha on the GPU and multiplies again when the output needs it.

Examples:

```sh
# 1 input, parameter animated over time
ffmpeg -i in.mp4 -vf "gpufx=effect=vignette.zip:params='strength=clip(t/2\,0\,1)|color=#200040'" out.mp4

# 2-input transition
ffmpeg -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect=wipe-transition.zip:params='progress=clip((t-1)/1.5\,0\,1)|angle=45'" out.mp4

# chaining several effects: two filters, each with its own upload/readback
ffmpeg -i in.mp4 -vf "gpufx=effect=gaussian-blur.zip,gpufx=effect=gradient-map.zip:params='intensity=0.6'" out.mp4

# same result in one filter: a single upload and readback
ffmpeg -i in.mp4 -vf "gpufx=effect='gaussian-blur.zip|gradient-map.zip':params='gradient-map.intensity=0.6'" out.mp4
```

## 6. Frame path and performance

**Working now (P1 done):** frame planes in RAM → texture upload → built-in conversion pass → effect
passes → built-in conversion pass → copy back to RAM. libgpufx converts `rgba`, `rgba64le`, `nv12`,
`p010le`, `yuv420p`/`yuv422p`/`yuv444p` and their `10le` versions, `yuva420p`, `yuva444p` (and the
`yuvj` aliases) itself:

- Each plane is uploaded to an integer texture (`r8uint`, `rg8uint`, `r16uint`, `rg16uint`,
  `rgba16uint`: core WebGPU formats on every backend, unlike `r16unorm`, which needs a native-only
  feature). A compute pass applies the matrix (BT.601, BT.709, BT.2020 non-constant luminance) and range
  (limited/full) of the `AVFrame`, upsamples chroma bilinearly at its siting (left, centre, top-left, top,
  bottom-left, bottom; unspecified is left) and writes the RGBA texture the first effect reads. Straight
  8-bit RGBA skips the pass.
- On output a pass converts the RGBA result to the output format (chroma downsampled with a triangle
  filter, `[1 3 3 1]` centred, `[1 2 1]` co-sited) and packs each plane into a storage buffer, which is
  copied to one mappable buffer and read back.
- RGBA textures are `rgba16float` when a frame of the chain (an input or the output) has more than 8 bits,
  so 10-bit survives the chain; otherwise `rgba8unorm`. Package PNGs stay `rgba8unorm`.
- The filter: inputs without `formats` accept these formats directly (FFmpeg converts other formats to
  one of them); inputs with `formats` receive the frame as is. Formats, matrices (FCC, SMPTE 240M,
  YCgCo...) and BT.2020 constant luminance that libgpufx does not handle are converted with `swscale` to
  `rgba` (or `rgba64le` above 8 bits) as before; so is the output. A manifest without `output` may output
  any of these formats (`rgba` first), so an encoder taking `yuv420p` needs no `scale` after `gpufx`.
  Such an output may be YUV without alpha, dropping the alpha the effect writes: effects that produce alpha
  declare `output.formats`.
- Unspecified chroma siting is centre for full range frames (JPEG/MJPEG) and left otherwise.
- Each package compiles its `rgba8unorm` pipelines when it loads and its `rgba16float` ones when the
  first frame above 8 bits comes (that frame waits for the compile; an error names the package).
- `GPUFX_API_VERSION` only grows by additions: the filter accepts a library whose version is at least
  the header's.
- A disabled filter (timeline) converts input 0 to the output format on the GPU without running effects.

All `gpufx` filters in the same process share one GPU device.

Loaded packages are shared too. Each package (keyed by absolute path and GPU device) is read and compiled
only once per process: a `Program` holds the manifest, pipelines, PNG textures and
samplers. Each filter keeps its own `Effect` with parameter values, uniform buffers and frame
textures. When no filter uses the package any more, the `Program` is freed and the next open reads the
file again. Editing a zip file while a filter still uses that package has no effect, even for a filter
that opens the package after the edit.

The main costs are upload/readback and color conversion on the CPU. The roadmap to remove them step by step:

| Phase | Change | Benefit |
|-------|--------|---------|
| P1 (done) | Convert YUV (NV12/P010/yuv420p...) ↔ RGBA on the GPU in the runtime; `rgba16float` textures when a frame is above 8 bits | Drops `swscale`, supports 10-bit/HDR |
| P2 | Pipelining: double-buffered readback, no blocking on the previous frame | 2–3× throughput on discrete GPUs |
| P3 | **Zero-copy** with `AV_PIX_FMT_VULKAN`: create the wgpu device from `AVVulkanDeviceContext` (`wgpu-hal` `create_device_from_hal`) and import the `VkImage` of `AVVKFrame` | No trip through RAM when decoding/encoding with Vulkan |
| P4 | **CUDA** interop (NVDEC/NVENC): `hwmap` CUDA → Vulkan (external memory) or `VK_KHR_external_memory` directly | Works with `-hwaccel cuda` |
| P5 | **D3D11/D3D12** interop (Windows, QSV/AMF/D3D11VA) through a shared NT handle into wgpu's DX12 | Works with `-hwaccel d3d11va` |
| P6 | VAAPI/DRM-PRIME (Linux), VideoToolbox (`CVPixelBuffer` → `MTLTexture`) | Covers all the common hwaccels |

In every phase, **the package format and shaders do not change**: authors never need to know whether a frame comes from
the CPU or from CUDA.

### GPU graph inside one filter (done, C API v5)

A single `gpufx` runs a whole effect graph, so complex branching stays on the GPU on every
backend (Vulkan, D3D12, Metal, GL), without hardware frames:

```sh
ffmpeg -i a.mp4 -i b.mp4 -filter_complex "[0:v][1:v]gpufx=graph='[0]split[a][b]; [a]gaussian-blur.zip[ba]; [b]grayscale.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[x]; [x][1]wipe-transition.zip[out]'[v]" -map "[v]" out.mp4
```

The single quotes protect `;` and `[]` from the outer filter graph. Rules:

- Statements are separated by `;`; each reads labels, runs a node and writes labels.
- `[0]`, `[1]`... are the filter's input pads (named `in0`, `in1`...). Every pad up to the highest must be read.
- Any other label (letters, digits, `_`, `-`; no `.`, which would clash with `label.param`) is written once and read at most once (`split` it to read it twice).
- **Outputs**: the labels no statement reads are the filter's output pads, in the order they are written
  (several are allowed; the pad names are the labels). There is no explicit output list: a misspelled
  label shows up as an extra output pad, which FFmpeg reports as unconnected.
- A node is `split` (one label in, any number out), `null` (one in, one out), or packages chained with
  `|` as in `effect=`, which take as many labels as the first package has inputs and write one.
  `split` and `null` cost nothing: their outputs *are* their input (two edges reading one texture).
- An effect writes the size of its first input; output pad k takes the size, SAR and frame rate of the
  input pad its source comes from. Frames come at input 0's events (framesync as with several inputs).
- Each input pad is uploaded once, each output pad is read back once, all outputs through one shared
  readback buffer; the whole graph runs in one submission, effects in topological order. The output
  frames of one event are sent together.
- `effect='a.zip|b.zip'` is the linear graph: `EffectChain` is a wrapper around `EffectGraph`, and a single
  `Effect` runs through the same code. `effect` and `graph` are mutually exclusive.
- Parameters are named as in chains over all packages of the graph in statement order (`label.name`,
  `index.name`, bare name); `node.name` with a node's output label also works (`ba.radius`, `gb.strength`
  finds the one effect of `grayscale|vignette` that has `strength`). `sendcmd` keeps working.
- Checked when the filter is created: cycles, labels read but never written, written twice or read twice,
  unread input pads, label counts against a node's inputs, numeric output labels. Checked at configuration:
  the manifest size and format rules of every node (an edge carries its producer's size and the format
  negotiated between the two effects), and input pads read by effects with no common format.
- With `enable=`, a disabled graph sends each output's source input pad converted to the output format.
- Paths in a graph must not contain `[`, `]`, `;` or `|`.

C API (v5, additive): `gpufx_effect_open_graph`, `gpufx_effect_output_count`, `gpufx_effect_output_name`,
`gpufx_effect_output_source`, `gpufx_effect_output_pad_format[_count]`, `gpufx_effect_process_graph`,
`gpufx_effect_convert_graph`; see `gpufx.h`.

### VRAM budget (rule for every phase)

VRAM is limited, so GPU memory is kept as low as possible and nothing is duplicated:

- No copies on the way in or out: YUV plane textures and the converted RGBA texture are reused frame to
  frame, and the first effect reads the converted texture directly.
- Intermediate textures (pass outputs, chain links, graph edges) come from a pool keyed by size and
  format: a 1-input 2-effect chain of one pass each allocates two pass outputs, a third effect reuses the
  first. Textures whose lifetimes do not overlap share memory (ping-pong); a texture goes back to the pool
  right after its last reader, counted over the whole graph in execution order. A pass output that is a
  graph output is kept until readback. The plan is computed before anything is allocated
  (`EffectGraph::memory_plan`), so a wide graph costs only the textures alive at the same time, not one per
  node. Example, the diamond `[0]split[a][b]; [a]gaussian-blur[ba]; [b]grayscale|vignette[gb];
  [ba][gb]crossfade[out]`: five pass outputs share **3** pooled textures (blur's two passes and the gray
  frame are alive together; vignette reuses blur's first pass, crossfade the gray frame), plus one upload
  texture (straight RGBA is read directly) and one readback buffer: 5 frame-sized allocations
  (1920x1080 `rgba8unorm`: 3 x 7.9 MiB pooled, 41.5 MB in all), against 8 with one texture per pass
  output and a copy for `split` (5 + 1 + upload + readback).
- `rgba16float` (twice the size of `rgba8unorm`) only where precision needs it (inputs or outputs above
  8 bits); an all-8-bit chain stays `rgba8unorm`.
- Staging and readback buffers are shared, not per effect: one readback buffer holds every output of a graph. Textures are freed when the frame size changes.
- Package textures (PNG) belong to the shared `Program` and are loaded once per device.

### On-disk shader cache (`GPUFX_SHADER_CACHE`)
- `GPUFX_SHADER_CACHE=<dir>` keeps compiled pipelines across processes; unset, nothing is written.
  The directory is created if missing; if it cannot be written, gpufx warns once and runs without cache.
- One file per pipeline (`<sha256>.gpucache`), the hash covering the final shader source (prelude
  included), language, entry point, output format (`rgba8unorm`/`rgba16float`), gpufx and wgpu
  versions, backend and adapter (name, vendor, device, driver, driver_info). No mtime checks.
- Vulkan only: the device requests `Features::PIPELINE_CACHE` when the adapter has it, and each pass
  pipeline is created with a `wgpu::PipelineCache` seeded from its file (`fallback: true`, so data of
  another driver or wgpu version is dropped by wgpu's header check) and dropped right after; nothing
  stays in memory. Files are written through a temporary file + rename; unreadable or corrupt files are
  ignored and rewritten. `GPUFX_SHADER_CACHE_MAX_MB` (default 256) caps the directory, the least
  recently used files are removed first.
- Each file is the wgpu blob followed by its SHA-256, checked before the blob reaches wgpu (mismatch:
  ignored, recompiled, rewritten). The directory must be private to the user: on Unix a directory
  writable by other users is refused with a warning, since the files reach the driver. Stale temp
  files (over 1 h) and the size limit are handled once per device.
- D3D12, Metal, GL: wgpu 30 has no on-disk pipeline cache; only driver caches apply (known limit,
  DXIL caching is in [Backlog-vi.md](Backlog-vi.md)). The built-in conversion pipelines are not cached.

## 7. Effect package security

A zip package is untrusted data (downloaded from an effect marketplace):
- Block path traversal (`..`, absolute paths), and limit the number of files and the total unpacked size.
- No native code in the package: only shaders, validated by naga before they reach the driver.
- wgpu checks buffer/texture accesses; an infinite loop in a shader can hang the GPU →
  later phase: dispatch time limits and package signing (`signature` in the manifest).

## 8. Repo layout

```
crates/gpufx-core   Rust engine: package, manifest, params, runtime (wgpu)
crates/gpufx-ffi    libgpufx (.so/.dll/.dylib + .a) and include/gpufx.h
crates/gpufx-cli    the `gpufx` command: info, check, pack, run (test effects without FFmpeg)
ffmpeg/             vf_gpufx.c and integrate.sh (adds the filter to the FFmpeg source tree)
external/FFmpeg     FFmpeg submodule, pinned to n9.0-2-g03d9533176 (release/9.0) = the prebuilt's commit
docker/, build.sh   build FFmpeg + gpufx with one command in Docker (linux64, win64)
examples/effects    36 effects: color adjustment, blur, sharpen, chroma key, overlay, transitions...
scripts/            build-prebuilt.sh (builds only libavfilter, swaps it into the prebuilt FFmpeg),
                    test-bundle.sh (runs the effects through the package's ffmpeg),
                    install-libgpufx.sh (builds + installs the .pc for pkg-config),
                    pack-effects.sh/.ps1 (only packages effects into zips)
```

## 9. Distribution builds

**Fast way (what CI uses):** `scripts/build-prebuilt.sh [linux64|win64]` downloads the prebuilt FFmpeg
9.0 shared build (tqk2811/FFmpegBuild), builds `libgpufx` and **only `libavfilter`** from the
submodule with `--disable-everything` + `docker/keep-filters.txt` + gpufx, then swaps
`libavfilter.so.12` / `avfilter-12.dll` in the package. Conditions for sharing the same ABI:

- the same FFmpeg commit as the prebuilt (the submodule pins `03d9533176`, and the script checks it);
- the same major name (`libavfilter.so.12`, `avfilter-12.dll`); the script stops if the prebuilt
  has no file with that name;
- the ffmpeg CLI uses only the public API and looks up filters by name at run time, so removing filters does not
  break library loading. The list of kept filters must include the filters the CLI inserts itself: `null`/`anull`,
  `format`/`aformat`, `scale`/`aresample`, `trim`/`atrim`, `apad`, `crop`, `hflip`, `vflip`,
  `transpose`, `rotate`.
- Linux: the RUNPATH of `libavfilter` is `$ORIGIN` (set with `patchelf`, because FFmpeg's configure
  turns `$$` into the PID), and every file in `bin/` gets its RPATH changed to `$ORIGIN/../lib`.
  Before swapping, the script compares the export table (`nm -D`) of the new `libavfilter` with the prebuilt's: if any
  symbol is missing, it stops.
- The trimmed `libavfilter` links only `avutil`, `swscale`, `swresample`, so `avcodec`/`avformat`/`avdevice`
  are not built. SIMD is enabled if `nasm` is available.
- win64: `avfilter-12.dll` uses `msvcrt.dll` while the prebuilt uses UCRT (see
  [Backlog-vi.md](Backlog-vi.md) (Vietnamese)).
- win64: `bin/` holds `dxcompiler.dll` (DXC, downloaded from NuGet by
  `scripts/fetch-dxc.sh`, sha256 checked). wgpu finds it next to `ffmpeg.exe` to compile
  shaders for D3D12; without it wgpu falls back to the old FXC, which takes minutes on
  loop-heavy shaders (the falling leaves). `WGPU_DX12_COMPILER=fxc` forces FXC.

`scripts/test-bundle.sh dist/<target>` runs every effect, expression, `sendcmd`, timeline and
the cases that must report errors through the package's `ffmpeg`. CI runs it for linux64 (lavapipe) and for
win64 on a `windows-latest` runner.

**Full build:** `./build.sh [linux64|win64|all]` (or `build.ps1` on Windows) builds the Docker image, builds
`libgpufx` with Rust, copies the `external/FFmpeg` submodule to a temporary directory (the submodule is left
untouched), runs `integrate.sh`, then configures FFmpeg with:

- `--disable-filters`, then re-enables **all audio filters** plus the minimal list in
  `docker/keep-filters.txt` (`null`, `format`, `scale`, `trim`, `crop`, `hflip`, `vflip`,
  `transpose`, `rotate`, `sendcmd`, `split`, `gpufx`). The video filters that are kept are the infrastructure
  that the ffmpeg CLI inserts itself (trim for `-ss/-t`, rotation from metadata) or that gpufx needs (converting
  YUV ↔ RGBA). gpufx converts the common YUV formats on the GPU itself (P1); `scale` stays for the
  other formats.
- `libgpufx` is linked dynamically: on Linux `rpath=$ORIGIN` finds `libgpufx.so` next to `ffmpeg`,
  and on Windows `gpufx.dll` sits next to `ffmpeg.exe`. The DLL depends only on system DLLs
  (checked with `objdump`).
- win64 is cross-compiled with mingw-w64 like BtbN/FFmpeg-Builds. macOS is not available yet (it needs a
  native build on a Mac).

## 10. Roadmap

1. **M0 – Prototype (this PR):** zip packages, WGSL + GLSL, multiple passes, multiple inputs, textures,
   parameters + expressions, FFmpeg 9.0 filter, CLI, 5 sample effects, automated tests.
2. **M1 – Shaders:** SPIR-V/HLSL/Slang, a Shadertoy `mainImage` wrapper, `#include` of shared shader
   libraries (color, noise, blend modes), hot-reload during development, output size different from the input
   (crop/zoom/pad), optional samplers (nearest/repeat/mirror).
3. **M2 – Performance:** P1–P2 in section 6, benchmarks on NVIDIA/AMD/Intel/Apple.
4. **M3 – Zero-copy:** P3–P6.
5. **M4 – Ecosystem:** package signing, an effect store, preview/visual parameter tools,
   converters for some common effect formats (GL Transitions, `.cube` LUT).
