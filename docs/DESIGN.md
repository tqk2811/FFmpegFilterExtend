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
| R3 | Multiple hardware / APIs | Vulkan, DirectX 12, Metal through **wgpu**; CUDA/D3D11/VAAPI through interop (phase 2). OpenGL was dropped: it cannot share FFmpeg frames and has no R8/R16 storage textures for YUV planes |
| R4 | Effects loaded externally, no FFmpeg rebuild | A single `gpufx` filter built **once**; effects are zip packages |
| R5 | Use Rust or C/C++ | The engine is written in **Rust**; the glue into FFmpeg is one small C file |

## 2. Architecture overview

```
 ffmpeg -vf "gpufx=effect='vignette.zip=strength=0.8'"
            │
            ▼
 ┌────────────────────────────┐   C ABI (gpufx.h)    ┌──────────────────────────────────┐
 │ libavfilter/vf_gpufx.c     │ ───────────────────▶ │ libgpufx (Rust, crates/gpufx-ffi) │
 │  - option effect/graph     │                      │  gpufx-core:                      │
 │  - dynamic input pads from │                      │   package  : read zip / directory │
 │    the manifest (1..N      │                      │   manifest : schema, validation   │
 │    inputs)                 │                      │   params   : uniform layout       │
 │  - framesync, many inputs  │                      │   runtime  : compile shaders,     │
 │  - expressions in t, n     │                      │              run passes on wgpu   │
 │  - sendcmd / timeline      │                      │                                   │
 └────────────────────────────┘                      └───────────────┬──────────────────┘
                                                                     │ wgpu
                                         ┌────────────┬──────────────┼─────────────┐
                                         ▼            ▼              ▼             ▼
                                      Vulkan      DirectX 12       Metal       (WebGPU)
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
| 3 | `smp` | Linear sampler, clamp, linear between mip levels |
| 4.. | input/texture/pass names | Textures to read (`texture_2d<f32>`; `texture_2d_array<f32>` for package textures with `layers`/`grid`) |

Package textures (api 2) can be texture arrays (`layers`, or an atlas cut by `grid`), with mip chains made
on the CPU and premultiplied alpha, all once when the `Program` loads; image sizes are checked from the PNG
headers (4096 a side, 64 M texels per package, the device limits) before anything is decoded. An input with
`mipmaps` gets its mip chain on the GPU every frame, in its own texture (the input slot or the pooled
texture of the effect writing it; pooled textures with and without mips are kept apart), so nothing is
copied. An `expr` parameter is compiled into the shaders as `gpufx_expr_<name>`, generated from a parsed
tree; an effect whose expressions differ from the defaults builds its own pipelines when they change
(the `Program` keeps the default ones). See [EFFECT_FORMAT.md](EFFECT_FORMAT.md).

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
gpufx=effect='<zip|directory>[=k=v[:k=v...]][|<zip>[=k=v...]...]'[:backend=auto|vulkan|dx12][:shortest=0|1][:out_format=<pix_fmt>][:passthrough=auto|off]
gpufx=graph='[0]split[a][b]; [a]x.zip[c]; [c][b]y.zip=k=v[out]'[:backend=...][:shortest=0|1][:out_format=<pix_fmt>][:passthrough=auto|off]
```

- **effect**: path to the package. The filter's number of inputs comes from the manifest.
- **Effect chain** `effect='a.zip|b.zip|c.zip'`: runs one after another like three chained filters, but
  all passes fit in a single GPU submit, without intermediate frames.
  The filter's inputs are the inputs of the first effect; only the first effect may have multiple inputs. The output
  follows the rules of the last effect. The rules of the later effects are checked as when chaining filters:
  the format is the first one in the previous effect's `output.formats` that the next effect accepts,
  and the size is the size of the first input. The frame stays RGBA on the GPU and is not converted to that format.
  Each effect takes its own inline parameters (`effect='gaussian-blur.zip=radius=8|vignette.zip=strength=0.6'`, see
  "Inline parameters" below). Spaces around `|` are ignored.
- **graph**: a whole effect graph with several inputs and outputs, in place of `effect`; see
  "GPU graph inside one filter" in section 6.
- **GPU frames out only**, like the `*_cuda` filters: every output is a Vulkan, D3D12, D3D11 or VideoToolbox frame, so
  `hwdownload,format=<fmt>` or `gpufx_download,format=<fmt>` must come before CPU filters and encoders. Inputs
  may be GPU frames of that API or software frames, which the filter uploads itself (`av_hwframe_transfer_data`
  into its own frames context per input): as they are when the device takes the format, else as nv12/p010le
  (4:2:0 YUV) or RGBA converted by swscale; frames whose matrix the GPU does not convert go up as RGBA. The
  device is the one of the GPU inputs, else
  `-filter_hw_device` (`AVFILTER_FLAG_HWDEVICE`), and its type picks the API; with software inputs only and
  no device the filter fails and names the options to add. A `-filter_hw_device` of another API than the
  GPU inputs is refused (it sets the output format); one of the same API but another device is ignored
  (their device wins, software inputs are uploaded there, with a warning). The `backend` option is for testing only (`auto` follows the frames); `backend=metal` is refused except on macOS (the library and the
  CLI keep it). Adding an API is one entry in `hw_apis[]` plus
  its cases in the per-API switches of `vf_gpufx.c`.
- **out_format**: forces the pixel format of every output (on Vulkan/D3D frames: the sw_format of the
  output frames context). It must be in the effect's output formats and converted on the GPU by libgpufx
  (`gpufx_format_supported`), and for GPU frames FFmpeg must make storage images of it; otherwise the
  filter fails at configuration. Default: the source input's format (for a software input, the format it
  is uploaded in) when the effect may output it, else its first output format the GPU writes (see "Vulkan frames"). Use: `out_format=rgba` between separate `gpufx` filters, so the middle
  ones skip the YUV ↔ RGBA conversions (the last one goes back with `out_format=nv12`).
  Limits: one format for every output of the filter; on D3D frames only nv12, p010le, rgba and rgba64le; on VideoToolbox frames nv12 and p010le.
- **passthrough** (`auto`, `off`; default `auto`): what the filter does while timeline `enable=`
  turns it off. `auto` hands each output its source input's texture relabelled as an output frame
  (the input's buffers with the output link's frames context, no GPU copy) when the GPU copy would
  leave the pixels unchanged and the next filter is `gpufx`, `gpufx_download` or `hwdownload`
  (filters that read a frame only through its frames context and texture). It needs a GPU frame not
  uploaded by gpufx; the same size, sw_format, device, colorspace, range and alpha mode as the
  output link; `out_format` unset or the same; and textures the output's frames context can
  describe: Vulkan same tiling, plane formats, frame flags (but the multiplane one), create flags and layers and at
  least the usage readers need (sampled, transfer source, host transfer when the output context
  has it); D3D12 same DXGI format, no texture array; D3D11 any (hwdownload copies the frame's
  texture and index); VideoToolbox never. With several outputs, all of them or none. Other next
  filters (encoders, `null`, ...) and `off` get the GPU copy as before. The output frames context
  holds the frames context of every texture it relabelled, so the textures outlive every frame and
  every gpufx downstream that keeps wrappers of them.
- **bypass** (`0`, `auto`; default `0`): which input a filter disabled by timeline `enable=` passes
  (relabelled or copied as above). `0`: each output's source input pad (input 0 for one effect).
  `auto`: that pad until the filter has been enabled for one frame, then the last input pad; made
  for transitions (input 0 fading into the last input) that should go on showing the clip they
  ended on: `[a][b]gpufx=effect=xfade.zip:enable='between(t,2,3)':bypass=auto`. After the first
  window it keeps the last input, also before later windows. The chosen pad must have the size of
  the output, else the event fails with an error (`EINVAL`), never another input.
- **Inline parameters**: written right after the package name, like the options of a native FFmpeg filter:
  `pkg.zip=key=value:key2=value2`, in `effect=` (also in a chain: `effect='a.zip=k=1|b.zip'`) and in every node of
  `graph=` (`[b]grayscale.zip|vignette.zip=strength=0.6[gb]`). Keys are named (no positional values). A value is
  a literal (`0.5`, `1,0,0`, `#ff8800`) or an **FFmpeg expression** in `t`, `n`, `w`, `h`, `a` (`w/h`), `sar`,
  `dar` (`a*sar`), re-evaluated for every frame. This is how you do keyframes/transitions without external tools.
  An unknown key is an error naming the effect and the key; so is a key given twice. The filter has no
  `params` option; to change values while the stream runs use the `sendcmd` command below.
  - **Escaping.** Put the whole `effect=`/`graph=` value in `'...'`. FFmpeg's own option parser splits the filter
    options at `:` *after* it removes those quotes, so in an ffmpeg command line inline keys are separated by `&`
    (needs no escaping; the FFmpeg-style `:` is also accepted but must be written `\:`, e.g. `a=1\:b=2`; a single
    key needs no separator), and commas in expressions keep the usual `\,`:
    `-vf "gpufx=effect='wipe.zip=progress=clip(t/2\,0\,1)&angle=45'"`,
    `effect='vignette.zip=strength=0.7'`. Inside the effect/graph string itself (after FFmpeg's unescaping),
    `\` escapes one of `\ ' : & ; | = [ ]` (`\&` is a literal `&` in a value; before any other character the `\` stays literal, so Windows paths
    work) and `'...'` quotes a value; commas need no escaping at this level.
- **Inline `enable=<expr>`** on an effect switches that effect per frame (on while the expression is not 0; a
  constant is an expression too): `effect='a.zip|b.zip=enable=lt(t\,2)'`. In a graph node of several effects
  (`grayscale.zip|vignette.zip`) put `enable` on each effect that should switch. It is not the filter's own
  timeline option `enable=`, which stays outside the effect string. No package may declare a parameter named
  `enable`. An effect switched off copies its first input into its output texture
  (every effect has its first input's size), so the plan, the pooled textures and the bindings of the
  rest of the graph stay as they are and toggling allocates nothing. Switching an effect off saves
  its shader work but not all of it: the copy is still one compute pass, and the effect keeps its
  output texture. With every effect off, the event is handled as a disabled filter (relabel when
  `passthrough` allows, else the GPU bypass), and `n` still counts.
- **Inline `bypass=0|auto`** on an effect: the input an effect switched off copies. `0` (default) its first
  input; `auto` its first input until its `enable` expression has been true once, then its last input (an effect
  of one input keeps it); any other value is an error. Any input may be copied, so the plan keeps every input of
  an effect alive until the effect's last pass. An input of another size than the effect's output makes the
  frame fail. With every effect off, the outputs are the input pads the chosen inputs lead to. No package may
  declare a parameter named `bypass`. This is not the filter option `bypass=` (which sets the input a filter
  disabled by `enable=` passes).
  `auto` rests on the history of the frames processed: an `enable` window shorter than one frame
  interval, or a stream whose first frame is already past the window (trim, seek), never sets it and
  stays on input 0; it is not reset on a seek; after the first window it is always the last input.
  FFI (API 11, also `gpufx_effect_node_effects`): `gpufx_effect_set_node_bypass`,
  `gpufx_effect_set_bypass`, `gpufx_effect_bypass_pad`.
- **sendcmd / zmq**: `params` is a runtime command (not a filter option) that changes values while the stream
  runs, for example `sendcmd=c='2.0 gpufx@fx params strength=0.2'`. It takes `node.name=value` pairs separated
  by `|`; a node is the package label, the 0-based index, a graph output label or the bare name, as in a chain
  or graph. It also accepts `<node>.enable=<expr>` and `<node>.bypass=0|auto`, which set every effect the node
  names and replace any inline value. These two keys exist only in this `params` runtime command (sendcmd/zmq);
  they are not filter options.
- **timeline** (`enable='between(t,1,3)'`) is supported.
- Multiple inputs use `framesync`: the first input decides the length and frame rate (an input with a
  different fps has its frames repeated or dropped). Another input that has not started yet is a black GPU frame (opaque for formats with alpha); one that has
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
VK="-init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk"   # or d3d12va=dx ... dx

# 1 input, parameter animated over time (gpufx uploads the frame, hwdownload brings it back)
ffmpeg $VK -i in.mp4 -vf "gpufx=effect='vignette.zip=strength=clip(t/2\,0\,1)&color=#200040',hwdownload,format=yuv420p" out.mp4

# 2-input transition
ffmpeg $VK -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='wipe-transition.zip=progress=clip((t-1)/1.5\,0\,1)&angle=45',hwdownload,format=yuv420p" out.mp4

# chaining several effects: two filters, the frame stays on the GPU between them
ffmpeg $VK -i in.mp4 -vf "gpufx=effect=gaussian-blur.zip,gpufx=effect='gradient-map.zip=intensity=0.6',hwdownload,format=yuv420p" out.mp4

# same result in one filter: one GPU submission
ffmpeg $VK -i in.mp4 -vf "gpufx=effect='gaussian-blur.zip|gradient-map.zip=intensity=0.6',hwdownload,format=yuv420p" out.mp4
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
| P3 (done) | **Zero-copy** with `AV_PIX_FMT_VULKAN`: the wgpu device is made from `AVVulkanDeviceContext` (`wgpu-hal` `device_from_raw`) and the `VkImage`s of `AVVkFrame` are read and written in place (see "Vulkan frames" below) | No trip through RAM when decoding/encoding with Vulkan |
| P4 | **CUDA** interop (NVDEC/NVENC): `hwmap` CUDA → Vulkan (external memory) or `VK_KHR_external_memory` directly | Works with `-hwaccel cuda` |
| P5 (done, untested on hardware) | **D3D12** frames in place on FFmpeg's `ID3D12Device`; **D3D11** through shared NT handles into wgpu's DX12 (see "D3D12 and D3D11 frames" below) | Works with `hwupload` on d3d12va/d3d11va; decoder frames with one GPU copy |
| P6 (VideoToolbox done, untested on a Mac) | VideoToolbox (`CVPixelBuffer` → IOSurface → `MTLTexture`, see "VideoToolbox frames" below); VAAPI/DRM-PRIME (Linux) | Covers all the common hwaccels |

In every phase, **the package format and shaders do not change**: authors never need to know whether a frame comes from
the CPU or from CUDA.

### GPU graph inside one filter (done, C API v5)

A single `gpufx` runs a whole effect graph, so complex branching stays on the GPU on every
backend (Vulkan, D3D12, Metal), without hardware frames:

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
- Parameters are written inline after each package of a node (`[b]grayscale.zip|vignette.zip=strength=0.6[gb]`, see
  "Inline parameters" in section 5), so a graph example with values reads
  `graph='[0]split[a][b]; [a]gaussian-blur.zip=radius=8[ba]; [b]grayscale.zip|vignette.zip=strength=0.6[gb]; [ba][gb]crossfade.zip=progress=clip((t-1)/1.5\,0\,1)&enable=between(t\,1\,3)&bypass=auto[x]'`.
  `sendcmd` addresses values at run time as `node.name=value` over all packages of the graph in statement order
  (package label, 0-based index, bare name, or a node's output label: `ba.radius`, `gb.strength` finds the one
  effect of `grayscale|vignette` that has `strength`).
- Checked when the filter is created: cycles, labels read but never written, written twice or read twice,
  unread input pads, label counts against a node's inputs, numeric output labels. Checked at configuration:
  the manifest size and format rules of every node (an edge carries its producer's size and the format
  negotiated between the two effects), and input pads read by effects with no common format.
- With `enable=`, a disabled graph sends each output's source input pad (or the pad `bypass` picks)
  converted to the output format.
- Paths in a graph must not contain `[`, `]`, `;` or `|`.

C API (v5, additive): `gpufx_effect_open_graph`, `gpufx_effect_output_count`, `gpufx_effect_output_name`,
`gpufx_effect_output_source`, `gpufx_effect_output_pad_format[_count]`, `gpufx_effect_process_graph`,
`gpufx_effect_convert_graph`; see `gpufx.h`.
Inline parameters (API 12, `GPUFX_API_VERSION` 12): `gpufx_effect_open_effects(effects, backend)` opens a chain
string with inline options, `gpufx_effect_open_graph` accepts them in every node, and `gpufx_effect_option_count` /
`gpufx_effect_option` read them back (constants are already applied; the caller evaluates expressions, `enable` and
`bypass`).

### Vulkan frames (done, C API v6)

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=effect=vignette.zip,gpufx=effect=sepia.zip,hwdownload,format=nv12" out.mp4
```

- Every input pad also takes `AV_PIX_FMT_VULKAN`, and output pads take only GPU formats (section 5).
  Inputs may mix Vulkan and software frames (the filter uploads the software ones on the same device).
  The sw_format of each Vulkan input must be one libgpufx converts (`nv12`, `p010le`, `yuv420p`, `rgba`...) and
  is checked against the manifest rules like a software format. The filter is `FF_FILTER_FLAG_HWFRAME_AWARE`.
- **One device.** `init` opens the packages on wgpu's noop device (pads and formats are known before
  negotiation, and no GPU device is made yet); the filter never makes a device of its own
  (`gpufx_effect_use_default_device` stays in the C API for other callers); when the links are configured, `gpufx_effect_use_vulkan` moves the effect to FFmpeg's device: libgpufx
  wraps the `AVVulkanDeviceContext` handles with `wgpu-hal` (`Instance::from_raw`, `expose_adapter`,
  `Adapter::device_from_raw`, then `create_device_from_hal`), compiles the packages again for that device
  (shared per `VkDevice` like any device) and copies the parameter values. Nothing of FFmpeg's is destroyed
  with it (no-op drop callbacks); the filter holds a reference to the device until the effect is freed.
- **wgpu only uses what the device has enabled.** wgpu-hal picks features (and drops its own bounds checks
  when `robustBufferAccess` is supported) from what the *physical device* supports, but FFmpeg enables only
  some of it. wgpu therefore sees the device through a wrapped `vkGetInstanceProcAddr`:
  `vkEnumerateDeviceExtensionProperties` lists only the extensions enabled on the device,
  `vkGetPhysicalDeviceFeatures[2]` ANDs the core features with the enabled ones and every extension
  feature struct with the same struct of FFmpeg's creation chain (promoted structs, such as timeline
  semaphores, take their fields from FFmpeg's `VkPhysicalDeviceVulkan11/12/13Features`). Queues created with flags
  (`VK_KHR_internally_synchronized_queues`) are fetched with `vkGetDeviceQueue2`.
- **Queue.** The first queue family with graphics and compute, queue 0 (wgpu records render passes and graphics
  barriers: on the compute-only family that NVIDIA lists first the device is lost; libgpufx refuses such a family). The filter holds FFmpeg's `lock_queue` around
  each call, so FFmpeg's own submissions (hwupload, other Vulkan filters) never race with wgpu's.
- **Frames.** One `VkImage` per plane, in FFmpeg's per-plane formats (`R8`, `R8G8`, `R8G8B8A8`, `R16`,
  `R16G16`, `R16G16B16A16` `_UNORM`): inputs need `disable_multiplane=1` on the device (or frames made that
  way); the output frames contexts gpufx makes use `AV_VK_FRAME_FLAG_DISABLE_MULTIPLANE` and need
  `STORAGE` usage. A multiplane image is refused at configuration with a message saying so, and so are input frames without
  `SAMPLED` usage. FFmpeg 9.0 makes `yuva420p`/`yuva444p` frames contexts without any usage by default (the
  ones `hwupload` makes work), so outputs fall back to another format, e.g. `rgba`. The output
  sw_format is the source input's when the effect may output it, else the first format of the output pad
  that libgpufx converts and that FFmpeg can make storage images of. `out_format` replaces that choice
  (that format or a configuration error). Chains of separate filters keep RGBA in between with
  `out_format=rgba` on all but the last (numbers in [BENCHMARK.md](BENCHMARK.md): faster than without it, still
  slower than one `graph=`).
- **Per frame**, no CPU wait: the filter locks each `AVVkFrame` once (`lock_frame`; a frame split upstream
  may sit on two pads), libgpufx wraps every image as a wgpu texture (`texture_from_raw`, external memory,
  no-op drop callback) or reuses the wrapper made on an earlier frame (an LRU of 16 frames per pad, keyed
  by image, semaphore, format and size; the bind groups made from them are cached the same way, so a
  pool of frames coming back in turn is bound once). wgpu sees every wrapper in `GENERAL` between calls;
  an image left in another layout (by `hwupload`, `hwdownload`, another filter) gets a raw barrier to
  `GENERAL` in a command buffer submitted first (from `UNDEFINED` for outputs). The filter holds the
  frames contexts of its inputs and outputs until the effect is freed, so no image is freed before its
  wrapper. It then records the input conversion (planes read as
  unorm textures), the effects and the output conversion (planes written as storage textures), moves every
  image to `GENERAL`, and submits once with a wait on every image's timeline semaphore at `sem_value` and a
  signal at `sem_value + 1` (`add_wait_semaphore`/`add_signal_semaphore`, each semaphore once). The filter
  then stores `layout`, `sem_value` and `access` in the `AVVkFrame`s and unlocks them.
- **VRAM:** no upload textures, no output storage buffers, no readback buffer; the pooled pass textures are
  the same as for software frames; each input keeps one converted RGBA texture (as for uploads), and the
  outputs are FFmpeg's pool frames themselves. A straight `rgba` input of a graph that is not deep, and
  whose mip chain no effect reads, has neither: the effects sample its image in place (no copy-in pass),
  and the effects reading it are bound to the new image every frame. Likewise a straight `rgba` output
  (`out_format=rgba`) of such a graph is written by the last pass of the effect making it, with no pooled
  texture and no copy-out pass, when nothing else reads that effect's output (no other effect or graph
  output, no mip chain, no other pass of the effect). Anything else, and bypassed frames, keep the copies.
- **Conversion passes of GPU frames** (Vulkan and D3D12): the input pass of a YUV frame converts 16x16
  pixels per workgroup, from the chroma samples they read loaded once into workgroup memory (not four
  clamped loads per pixel). A YUV output is written by one pass for all its planes: each invocation writes
  one chroma sample and the luma (and alpha) samples of its block, from a tile of pixels converted to YUV
  once, with the weights of the chroma filter computed per row and column. The RGBA plane pass picks
  channels with `select`, not a vector index known only when running (which NVIDIA moves to local memory).
  The bytes are the same as before (tests compare with the CPU path). Measured with one vignette on 1080p
  wgpu textures (RTX 4060 Laptop, 3000 frames): nv12 copy-in 0.108 → 0.087 ms, copy-out 0.130 → 0.105 ms;
  rgba copy-out 0.087 → 0.049 ms. The conversion is not fused into the effects' first and last passes:
  effects sample their inputs through a linear sampler (filtering the YUV planes does not give the RGB
  the copy gives) and every effect pass would need a pipeline per frame format.
- **Profiling:** `GPUFX_PROFILE=1` asks the device for timestamp queries and prints, when each graph is
  freed, its GPU time per frame for copy-in, effects and copy-out, and its CPU time per frame (prepare, bind,
  record, import, submit). It splits the frame into three compute passes and waits for frames four behind,
  so wall time is not representative while it is on.
- A disabled filter always converts the frame on the GPU into the output's frames context (no pass by
  reference: the output has its own frames context). An input that has not started shows a black frame
  uploaded once (opaque for formats with alpha); software inputs get one too, in their upload format.
- Rust: `GpuFrame` (plane textures of the effect's device) and `EffectGraph::encode_gpu`, which records a
  whole graph into the caller's command encoder without submitting (backend independent, the base of the
  D3D12 step); `GpuContext::from_vulkan` and `EffectGraph::process_vulkan` (`gpufx_core::vulkan`, Linux and
  Windows) add the Vulkan sharing and synchronisation. C API (v6, additive): `gpufx_vulkan_supported`,
  `gpufx_effect_use_vulkan`, `gpufx_effect_process_vulkan`; see `gpufx.h`.
- Build: `scripts/build-prebuilt.sh` configures libavfilter with `--enable-vulkan` when the prebuilt
  `libavutil` has Vulkan and the Khronos Vulkan-Headers are found (cloned, tag `v1.4.321`; FFmpeg wants a
  header newer than Ubuntu noble's), and keeps `hwupload`, `hwdownload`, `hwmap`. Otherwise gpufx is built
  without Vulkan frames and the tests skip them.
- **Decoders:** the Vulkan decoders (`-hwaccel vulkan`) output multiplane images, so their frames are refused
  for now (`hwdownload,hwupload` or a GPU copy into per-plane images is needed; backlog).
- **Submissions** of one shared device are serialised by a mutex in libgpufx held from staging the semaphores
  to `queue.submit` (besides FFmpeg's `lock_queue`), inside a wgpu error scope; a submission wgpu refuses has
  its semaphores taken back and makes later Vulkan frames on that device fail cleanly.
- Tested on lavapipe: the bundle test compares the framemd5 of `hwupload,gpufx,...,hwdownload` with
  software frames that gpufx uploads itself (rgba, nv12, yuv420p, yuv444p, p010le, yuv420p10le, rgba64le, a graph whose two inputs are one split
  frame, two filters in a row, a changed output format); they are identical. Rust tests check
  `encode_gpu` against the CPU path byte for byte.

### Transfer filters `gpufx_upload` / `gpufx_download` (Vulkan)

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx=effect=vignette.zip,gpufx=effect=sepia.zip,gpufx_download,format=nv12" out.mp4
```

Drop-in replacements for `hwupload` / `hwdownload` on Vulkan devices (`ffmpeg/vf_gpufx_transfer.c`, plain C
on FFmpeg's internal Vulkan helpers `libavutil/vulkan.h`, no libgpufx). Why: on NVIDIA FFmpeg 9.0 copies
through a staging buffer (host image copy and host memory import are off), and `hwdownload` waits on the CPU
for every copy (`ff_vk_exec_wait`), so CPU and GPU take turns. On the Intel Windows driver FFmpeg 9's host
image copies are broken; the frames contexts gpufx creates drop the host-transfer usage, and `gpufx` refuses
`hwupload` frames there ([INTEL_VULKAN.md](INTEL_VULKAN.md)).

- **gpufx_upload** (`depth`, default 3): the frames context is made on `-filter_hw_device` like `hwupload`
  (input formats: the device's sw formats whose planes map 1:1 to Vulkan planes). A ring of `depth`
  persistently mapped, host-coherent staging buffers, one per execution context: memcpy into the slot,
  barrier + `vkCmdCopyBufferToImage` per plane, submit without waiting. The CPU waits only when it comes
  back to a slot whose copy is still running (`ff_vk_exec_start` waits for that slot's fence).
- **gpufx_download** (`latency`, default 2): `activate` filter. Frame k is submitted
  (`vkCmdCopyImageToBuffer` into slot k mod (latency+1), host-cached memory), frame k-latency is waited
  for (normally done), invalidated, copied into a buffer from `ff_get_video_buffer` and sent with its
  props. On EOF the frames in flight are flushed, then the status is passed on. The output format must be
  the frames' sw_format (add `format=<sw_format>` after it, like `hwdownload`).
  With sparse input (live sources) each frame comes out only `latency` frames later; `latency=0` turns
  the pipelining off. Neither filter takes a frame size change mid-stream (`hwupload`/`hwdownload` do):
  the graph stops with EINVAL.
- **Sync**: `ff_vk_exec_add_dep_frame` (lock_frame, wait on each image's timeline semaphore at
  `sem_value`, signal `sem_value + 1`), `ff_vk_frame_barrier` with no queue family transfer, and
  `ff_vk_exec_submit` (which takes FFmpeg's `lock_queue`), on FFmpeg's graphics queue family, the one
  `gpufx` and wgpu use. So they mix with `hwupload`, `hwdownload`, `gpufx` and the `*_vulkan` filters.
  The execution holds a reference to the frame until its copy has been read back.
- **Planes**: multiplane images (`PLANE_n` aspects) and one image per plane (`disable_multiplane=1`) both
  work. Each plane has its own region in the staging buffer: rows aligned to
  `optimalBufferCopyRowPitchAlignment` (and a multiple of the texel size, as `bufferRowLength` is in texels),
  plane offsets to `optimalBufferCopyOffsetAlignment` (at least 16). The copied size is the link's size
  (decoder frames contexts may be larger).
- **Queues**: `ff_vk_exec_pool_init` asks for its queues with the flags libavfilter was compiled for; the
  prebuilt libavutil creates them with `VK_KHR_internally_synchronized_queues`, unknown to the Vulkan headers
  of the build, and `vkGetDeviceQueue2` then returns no queue. The filters fetch the queues again with the
  device's `queue_flags` (the validation layer still reports the pool's first call once, VUID-06225).
- Build: `integrate.sh` adds `vf_gpufx_transfer.o vulkan.o` (libavfilter's copy of `libavutil/vulkan.c`)
  and `gpufx_upload/download_filter_deps="vulkan"`; `docker/keep-filters.txt` keeps both.
- Tests (`scripts/test-bundle.sh`): nv12, yuv420p and rgba round trips are bit-exact, multiplane and
  `disable_multiplane=1`, mixed with `hwupload` / `hwdownload`; `gpufx` between them equals the software
  path; every frame comes out with `latency=4`. Also checked by hand: p010, the Vulkan validation layer
  (no VUID from the copies; plain `hwupload`/`hwdownload` give VUID-00174/00191 there).

Measured on the 90 s clips (RTX 4060 Laptop, idle GPU): see [BENCHMARK.md](BENCHMARK.md).

### D3D12 and D3D11 frames (C API v7; built and cross-compiled, run only by the Windows CI job)

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=effect=vignette.zip,hwdownload,format=nv12" out.mp4
ffmpeg -init_hw_device d3d11va=dx -filter_hw_device dx -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=effect=vignette.zip,hwdownload,format=nv12" out.mp4
```

- Pads also take `AV_PIX_FMT_D3D12` and `AV_PIX_FMT_D3D11` (when libavfilter is built with d3d12va/d3d11va and
  libgpufx is a Windows build). Same rule as Vulkan: all inputs and outputs are frames of one API, or none.
  sw_formats: `nv12` and `p010le` in practice (the only ones FFmpeg's d3d12va makes, and the only ones of
  d3d11va that gpufx reads); libgpufx also takes RGBA8/RGBA16 resources (`rgba`, `rgba64le`) from other callers.
  Others are refused at configuration (d3d11va's BGRA would need a swizzle: backlog). Textures with more than
  one mip level are refused.
- **D3D12, one device.** wgpu-hal 30 has no `device_from_raw` for DX12, but D3D12 devices are singletons per
  adapter and process: libgpufx opens the wgpu DX12 adapter whose LUID is the device's
  (`ID3D12Device::GetAdapterLuid`) and checks that wgpu got the very same `ID3D12Device` (COM identity);
  otherwise (another D3D12 runtime such as an Agility SDK, an adapter wgpu filters out like the headless
  "Microsoft Basic Render Driver" duplicate of WARP) it refuses with a message. wgpu has its own command
  queue on that device.
- **D3D12 frames in place.** `AVD3D12VAFrame.texture` is wrapped once per plane (`texture_from_raw` +
  `with_plane_slice`: R8/RG8 or R16/RG16 views of the NV12/P010 resource). Frames rest in
  `D3D12_RESOURCE_STATE_COMMON` (FFmpeg's convention); libgpufx records the transitions to the state of each
  use and back itself, per subresource of the frame's slice, in command lists of its own before and after
  wgpu's, and creates the wrappers in that state, so wgpu records no barrier (it would transition the whole
  resource once per plane wrapper). One submission waits for each frame's `sync_ctx.fence` at `fence_value`
  and signals `fence_value + 1` (each fence once); the filter stores the value. FFmpeg's D3D12 upload does not
  wait for a frame's fence before writing it, so a call first waits on the CPU for the previous call's
  submission (one event in flight).
- **One GPU copy when in place is impossible**, into a texture libgpufx keeps per pad and plane (VRAM: one
  frame per such pad): an input that is a slice of a texture array (`AV_D3D12VA_FRAME_FLAG_TEXTURE_ARRAY`,
  decoders) or larger than the frame or denied to shaders, and an output without
  `D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS`. The output frames contexts gpufx makes ask for unordered
  access first and fall back to frames written by a copy (verbose message); each candidate context is probed
  with one `av_hwframe_get_buffer`, since a device may accept the context but fail to create its textures.
- **D3D11.** wgpu has no D3D11 backend: the effect runs on wgpu's D3D12 device of the D3D11 device's adapter
  (LUID through `IDXGIDevice`). Textures with `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` are opened there with
  `CreateSharedHandle`/`OpenSharedHandle` without a copy (kept open, up to 64, holding a reference to the
  texture). The output frames contexts gpufx makes are such textures (`SHARED | SHARED_NTHANDLE`, bind
  `SHADER_RESOURCE | UNORDERED_ACCESS`, without UAV if the device refuses it: then the D3D12 copy above), so
  outputs are not copied. Inputs from `hwupload` or decoders are not shareable and are copied once on the
  D3D11 immediate context (`CopySubresourceRegion`, also resolving array slices) into a shared texture
  libgpufx keeps per input pad (VRAM: one frame per input pad). D3D11On12 was not used: it wraps D3D12
  resources for D3D11, while the frames here are made by FFmpeg's D3D11 device; keyed mutexes would also work
  but need `SHARED_KEYEDMUTEX` textures and CPU-side acquire/release. Order: a D3D12 fence shared with the
  D3D11 device (`ID3D11Device5::OpenSharedFence`, D3D11.4): the immediate context signals `v` and is
  flushed, the D3D12 submission waits `v` and signals `v + 1`, the immediate context waits `v + 1`, so
  FFmpeg's later D3D11 work (`hwdownload`, encoders) waits on the GPU, no CPU wait. The filter holds
  `AVD3D11VADeviceContext.lock` during the call.
- Rust: `GpuContext::from_d3d12` / `from_d3d11`, `EffectGraph::process_d3d12` / `process_d3d11`
  (`gpufx_core::d3d12`, `cfg(windows)`, built on `encode_gpu`). C API (v7, additive): `gpufx_d3d12_supported`,
  `gpufx_effect_use_d3d12`, `gpufx_effect_process_d3d12`, `gpufx_effect_use_d3d11`,
  `gpufx_effect_process_d3d11`; on other systems they fail with a message.
- Build: `scripts/build-prebuilt.sh win64` adds `--enable-d3d11va --enable-d3d12va` when the prebuilt
  `libavutil` has them (it does), fetching `d3d12.h`, `d3d12sdklayers.h`, `d3d12video.h` of mingw-w64 v12.0.0
  when the installed mingw-w64 (Ubuntu noble: 11) has no `d3d12video.h`.
- Tests: `test-bundle.sh` runs nv12/p010le vignette, two filters in a row, a graph whose two inputs are one
  split frame, the timeline, a late second input and a mixed-input rejection for both APIs, on adapters 0-3,
  and skips when there is no device or wgpu cannot share it. The CI job `ffmpeg-windows` runs them on WARP;
  they have not been run on hardware. With `REQUIRE_D3D=1` (set in both win64 CI jobs) a skip fails the test (D3D12 is exempt when the FFmpeg has no d3d12va hwdevice, since FFmpeg's D3D frames are D3D11)
  and a build without D3D12/D3D11 frames (no d3d12va/d3d11va, header fetch or sha256 failure) fails the build;
  the test prints a line of the APIs tested and skipped.
- The blank frame of an input that has not started (all GPU APIs, Vulkan included) comes from a small frames
  context of the filter's own, made like the input's (device, sw_format, image flags), not from the input's
  pool, which may have a fixed size upstream.
- The shared DX12 instance ignores `VALIDATION`, `GPU_BASED_VALIDATION` and `DEBUG` from the environment: the
  device is FFmpeg's too.

### VideoToolbox frames (C API v9; macOS, compiled but not yet run on a Mac)

```sh
ffmpeg -init_hw_device videotoolbox=vt -filter_hw_device vt -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=effect=vignette.zip,hwdownload,format=nv12" out.mp4
```

- Pads also take `AV_PIX_FMT_VIDEOTOOLBOX` (when libavfilter is built with videotoolbox and libgpufx is a
  macOS build). sw_formats: `nv12` (`420v`/`420f`) and `p010le` (`x420`/`xf20`); the pixel format of each
  `CVPixelBuffer` is checked against the frames context's. Others (BGRA...) are refused at configuration, and
  software inputs that are not 4:2:0 cannot be uploaded (backlog).
- **Device.** The frames are `IOSurface`s, which any Metal device opens: libgpufx runs on wgpu's Metal adapter
  (high performance first), one context per process, and FFmpeg's VideoToolbox device is only held.
- **In place.** `CVPixelBufferGetIOSurface`, then one Metal texture per plane with
  `newTextureWithDescriptor:iosurface:plane:` (R8 + RG8 or R16 + RG16, usage shader read/write, shared storage;
  only unified-memory GPUs are taken, since managed textures would need a sync blit wgpu does not record), wrapped with `wgpu_hal::metal::Device::texture_from_raw` and
  `create_texture_from_hal`. The texture retains the surface, so wrappers are cached per pad by `IOSurfaceID`
  (16 frames × 4) like the Vulkan images, and dropping one releases the surface. An IOSurface plane larger
  than the frame is used from its top left corner.
- **No fence.** FFmpeg's VideoToolbox frames have no GPU sync object (uploads and downloads lock them on the
  CPU), so a call waits (`device.poll`) until its submission is done before returning.
- **Writing p010le** needs R16/RG16 storage textures (`TEXTURE_FORMAT_16BIT_NORM` and the adapter's format
  features): Apple GPUs have them; on a GPU without them a p010le output fails with a message naming the
  formats (no fallback yet: backlog).
- Rust: `GpuContext::from_videotoolbox`, `EffectGraph::process_videotoolbox`
  (`gpufx_core::videotoolbox`, `cfg(target_vendor = "apple")`, built on `encode_gpu`). C API (v9, additive):
  `gpufx_videotoolbox_supported`, `gpufx_effect_use_videotoolbox`, `GpufxVtFrame`,
  `gpufx_effect_process_videotoolbox`; on other systems they fail with a message.
- Tests: `test-bundle.sh` runs, on macOS only, nv12/p010le vignette against the Vulkan run or the software
  frames, two filters in a row, a split-frame graph, a late software input and a BGRA rejection. The CI job
  `ffmpeg-macos` builds FFmpeg from the submodule with VideoToolbox and runs it with `REQUIRE_VT=1`: a skip
  fails unless FFmpeg cannot create the device or there is no Metal adapter.

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
- Vulkan: the device requests `Features::PIPELINE_CACHE` when the adapter has it, and each pass
  pipeline is created with a `wgpu::PipelineCache` seeded from its file (`fallback: true`, so data of
  another driver or wgpu version is dropped by wgpu's header check) and dropped right after; nothing
  stays in memory. Files are written through a temporary file + rename; unreadable or corrupt files are
  ignored and rewritten. `GPUFX_SHADER_CACHE_MAX_MB` (default 256) caps the directory, the least
  recently used files are removed first.
- Each file is the wgpu blob followed by its SHA-256, checked before the blob reaches wgpu (mismatch:
  ignored, recompiled, rewritten). The directory must be private to the user: on Unix a directory
  writable by other users is refused with a warning, since the files reach the driver. Stale temp
  files (over 1 h) and the size limit are handled once per device.
- The key also holds the exact naga, wgpu-core and wgpu-hal versions (read from `Cargo.lock` by
  `build.rs`). Effect passes and the built-in conversion pipelines both go through the cache.
- D3D12: wgpu 30 has no on-disk pipeline cache there. When `dxcompiler.dll` is on the DLL search path,
  gpufx writes the HLSL itself with naga (registers matching wgpu-hal's root signature, `dxil.rs`),
  compiles it to DXIL (`cs_6_0`), keeps it as `<sha256>.dxil` (key adds DXC version and shader model)
  and loads it back with `Features::PASSTHROUGH_SHADERS` (requested only on D3D12 when a cache is
  configured). A blob D3D12 refuses is recompiled; if freshly compiled DXIL is refused too (no
  `dxil.dll`...), the file is removed; once two distinct shaders are refused that way, that device stops
  using DXIL. Without DXC, the normal path.
- `gpufx pack --precompile <dir> <out.zip>` compiles every pass (8-bit and `rgba16float` outputs, default
  `expr` values) on a D3D12 device (WARP is enough) and stores `compiled/dx12/<sha256>.dxil` (checksum
  appended) in the package; the key has no adapter, driver or DXC version, so machines without DXC
  can use it. A `compiled/` folder in `<dir>` is never copied. At run time the blobs are used only with
  `GPUFX_TRUST_PRECOMPILED=1` (then even without `GPUFX_SHADER_CACHE`): packages are not signed yet and
  passthrough shaders are not checked by wgpu. The variable is read when a context is created and then
  trusts every package that context opens; the appended SHA-256 only proves integrity, not who built the
  package. Missing or refused blobs fall back to the normal path (a refused blob is logged once);
  `ShaderCacheStats::precompiled` counts the hits.
- Metal: no on-disk cache in wgpu 30; only driver caches apply.

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
  (checked with `objdump`). The win64 bundle also gets `dxcompiler.dll` and its license texts in `bin/`
  (`scripts/fetch-dxc.sh`, as in the prebuilt flow).
- win64 is cross-compiled with mingw-w64 like BtbN/FFmpeg-Builds. There is no macOS bundle; the CI job `ffmpeg-macos` builds FFmpeg from source on
  a macOS runner only to test the VideoToolbox path.

## 10. Roadmap

1. **M0 – Prototype (this PR):** zip packages, WGSL + GLSL, multiple passes, multiple inputs, textures,
   parameters + expressions, FFmpeg 9.0 filter, CLI, 5 sample effects, automated tests. Since then
   (api 2): texture arrays, mipmaps (package textures and inputs), premultiplied textures, `expr`
   parameters compiled into the shaders; sprites/particles as stateless shaders (`falling-*`).
2. **M1 – Shaders:** SPIR-V/HLSL/Slang, a Shadertoy `mainImage` wrapper, `#include` of shared shader
   libraries (color, noise, blend modes), hot-reload during development, output size different from the input
   (crop/zoom/pad), optional samplers (nearest/repeat/mirror).
3. **M2 – Performance:** P1–P2 in section 6, benchmarks on NVIDIA/AMD/Intel/Apple.
4. **M3 – Zero-copy:** P3–P6.
5. **M4 – Ecosystem:** package signing, an effect store, preview/visual parameter tools,
   converters for some common effect formats (GL Transitions, `.cube` LUT).
