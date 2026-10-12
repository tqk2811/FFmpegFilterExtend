Tiếng Việt: [EFFECT_FORMAT-vi.md](EFFECT_FORMAT-vi.md)

# Effect package format and how to write shaders (api 1)

## Package structure

A package is a `.zip` file (or a directory during development) with `manifest.json` at its root. Paths
in the manifest are relative to the package root and use `/`.

```
my-effect/
├── manifest.json
├── shaders/main.wgsl
└── textures/lut.png
```

Package and check:

```sh
gpufx check my-effect            # compile every shader, report errors with positions
gpufx run my-effect -i in.png -o out.png -p strength=0.8
gpufx pack my-effect my-effect.zip
```

Package several effects at once (no FFmpeg build or Docker needed):

```sh
scripts/pack-effects.sh                         # every directory in examples/effects -> dist/effects/*.zip
scripts/pack-effects.sh --check -o out my-fx    # compile the shaders on the GPU first, write to out/
.\scripts\pack-effects.ps1 -Check                # Windows
```

## manifest.json

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `api` | number | no (1) | Format version |
| `id` | string | yes | Identifier in reverse-DNS form |
| `name` | string | yes | Display name |
| `version`, `description` | string | no | |
| `inputs` | array | no (`[{"name":"src"}]`) | The video inputs, in the filter's pad order, with their rules (see below) |
| `output` | `{formats}` | no (`{"formats":["rgba"]}`) | Allowed output pixel formats |
| `params` | array | no | Parameters, see below |
| `textures` | array of `{name, path}` | no | Bundled PNG images (LUT, mask) |
| `passes` | array | yes | The compute passes, run in order |

## Input/output rules

A package can declare which formats and sizes each input accepts and which format the output produces. A stream
that does not match **is rejected with an error** (the filter does not convert silently), and the error names the input and the rule:

```
unsupported: input `src` of `Chroma Key`: pixel format `gray` is not supported (accepted: yuv420p, rgba)
unsupported: input `second` of `Crossfade`: size 300x180 must equal the first input (320x180)
```

Each element of `inputs`:

| Field | Default | Meaning |
|-------|---------|---------|
| `name` | | Input name, also the texture name in the shader |
| `description` | | Description |
| `formats` | `[]` (any format) | Accepted pixel formats (FFmpeg names: `yuv420p`, `nv12`, `rgba`, `rgb24`...) |
| `width`, `height` | unrestricted | `{ "min": 16, "max": 4096, "multiple_of": 2 }`, each field is optional |
| `same_size` | `false` | The size must equal the first input (not for the first input itself) |

`output.formats`: the allowed output pixel formats, in order of preference. FFmpeg
picks one format from the list when linking filters; if a downstream filter demands a format outside the list,
FFmpeg inserts a converter after `gpufx`.

```json
"inputs": [
  { "name": "src", "formats": ["yuv420p", "nv12", "rgba"],
    "width": { "min": 64, "multiple_of": 2 }, "height": { "min": 64, "multiple_of": 2 } },
  { "name": "matte", "formats": ["gray"], "same_size": true }
],
"output": { "formats": ["yuva420p", "rgba"] }
```

How the rules apply:

- **FFmpeg:** an input without `formats` behaves as before (FFmpeg converts to RGBA itself). An input with
  `formats` receives the stream's format as is; if it is not in the list, configuring the filter graph fails.
  To make it work, change the format first with `format=yuv420p,gpufx=...`. The size is checked
  at configuration and whenever the frame size changes. A misspelled format name is also an error.
- **`gpufx run`:** the format comes from the PNG (`rgba`, `rgb24`, `gray`, `ya8`, and the 16-bit versions
  `rgba64be`, `rgb48be`, `gray16be`, `ya16be`). The CLI always writes an RGBA PNG, so it does not check
  `output.formats`.
- Shaders always see 8-bit RGBA, whatever the input/output format is: the conversion happens outside the shader.

Each element of `params`:

| Field | Meaning |
|-------|---------|
| `name` | Name, also the field name in `params.<name>` |
| `type` | `float`, `int`, `bool`, `vec2`, `vec3`, `vec4`, `color` |
| `default` | A number, an array of numbers, `true/false`, or a string (`"#ff8800"`) |
| `min`, `max` | The value is clamped to this range |
| `description` | Description |

Types in the shader: `float`→`f32`/`float`, `int`→`i32`/`int`, `bool`→`u32`/`uint` (0 or 1),
`vecN`→`vecNf`/`vecN`, `color`→`vec4f`/`vec4` (RGBA 0..1).

Each element of `passes`:

| Field | Default | Meaning |
|-------|---------|---------|
| `shader` | | Shader file in the package |
| `language` | from the file extension | `wgsl` or `glsl` (`.glsl` and `.comp` are GLSL) |
| `entry` | `main` | The compute function (WGSL; GLSL is always `main`) |
| `inputs` | every input, then every texture | Textures this pass reads: input names, textures, or the output of a previous pass |
| `output` | `out` | Name of the texture this pass writes. The last pass is the result |

The output has the same size as the first input. Input/texture/param names must be valid identifiers,
must not collide with each other, must not start with `gpufx`, and must not use `globals`, `params`, `out_tex`, `smp`.

## Writing WGSL shaders

The runtime inserts the following declarations for you (the example is for a package with an input `src` and a parameter `strength`):

```wgsl
struct GpufxGlobals {
    size: vec2f,          // output size (px)
    time: f32,            // time (seconds); f32 loses precision on long clips
    frame: u32,           // frame number, counted per filter (not stable across seeks)
    time_int: i32,        // exact time: time_int + time_frac seconds,
    time_frac: f32,       //   time_frac in [0, 1), even when the time is negative
    pixel_aspect: f32,    // width / height of one pixel (SAR), 1 for square pixels
    gpufx_reserved: f32,
};
struct GpufxParams { strength: f32 };
@group(0) @binding(0) var<uniform> globals: GpufxGlobals;
@group(0) @binding(1) var<uniform> params: GpufxParams;
@group(0) @binding(2) var out_tex: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(3) var smp: sampler;
@group(0) @binding(4) var src: texture_2d<f32>;
fn gpufx_in_bounds(id: vec3u) -> bool
fn gpufx_uv(id: vec3u) -> vec2f          // pixel center, 0..1
fn gpufx_write(id: vec3u, c: vec4f)      // clamp to 0..1, then write
```

Time-based motion should rely on `time_int` and `time_frac` if the clip can be long: `time`
is an f32, so after one day its step is only about 0.008 s. See `falling-*/shaders/leaves.wgsl`, which counts
time in integer ticks.

All your shader needs is:

```wgsl
@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let c = textureSampleLevel(src, smp, gpufx_uv(id), 0.0);
    gpufx_write(id, vec4f(c.rgb * params.strength, c.a));
}
```

Notes:
- The runtime dispatches in **8×8** groups; use `@workgroup_size(8, 8)`.
- Compute shaders have no derivatives, so use `textureSampleLevel(..., 0.0)` or
  `textureLoad` instead of `textureSample`.
- Colors are 8-bit RGBA, 0..1, with no gamma conversion (sRGB values as in the video).

## Writing GLSL shaders

GLSL 450 compute in the Vulkan style (separate textures and samplers). If the file has a `#version`, the
prelude is inserted right after that line; otherwise the runtime adds `#version 450` itself.

```glsl
#version 450
layout(local_size_x = 8, local_size_y = 8) in;

void main() {
    uvec3 id = gl_GlobalInvocationID;
    if (!gpufx_in_bounds(id)) return;
    vec4 c = textureLod(sampler2D(src, smp), gpufx_uv(id), 0.0);
    gpufx_write(id, vec4(c.rgb * params.strength, c.a));
}
```

## Included examples

| Package | Demonstrates |
|---------|--------------|
| `examples/effects/vignette` | `float` + `color` parameters |
| `examples/effects/gaussian-blur` | 2 passes through an intermediate `tmp` texture |
| `examples/effects/wipe-transition` | 2 inputs (`first`, `second`), a `progress` parameter |
| `examples/effects/gradient-map` | A bundled PNG texture used as a LUT |
| `examples/effects/rgb-split` | GLSL, uses `globals.frame` as animated noise |
| `examples/effects/color-adjust` | Brightness, contrast, saturation, gamma, hue, color temperature |
| `examples/effects/grayscale`, `sepia`, `invert` | Basic color filters, an `amount` parameter |
| `examples/effects/sharpen` | 3×3 unsharp mask using `textureLoad` |
| `examples/effects/edge-detect` | Sobel |
| `examples/effects/pixelate` | Block mosaic |
| `examples/effects/mirror` | Horizontal/vertical flip, an `int` parameter |
| `examples/effects/transform` | Zoom, rotate, pan (Ken Burns), a `vec2` parameter |
| `examples/effects/fade` | Fade to a color |
| `examples/effects/chroma-key` | Green screen → alpha; input `formats` **rules**, output `rgba`/`yuva420p`/`yuva444p` |
| `examples/effects/overlay` | 2-input picture-in-picture, with a border |
| `examples/effects/crossfade`, `slide-transition`, `circle-reveal` | 2-input transitions; `same_size` **rule** |
| `examples/effects/clock-wipe` | Clock-hand transition, a `bool` parameter `reverse` |
| `examples/effects/collapse`, `expand` | The first clip shrinks into the center / the second clip grows out of the center: horizontal, vertical, box, circle (`mode`) |
| `examples/effects/dip-to-color` | Fade to a color (black by default), then reveal the second clip |
| `examples/effects/dissolve` | Random particles (integer hash, identical on every GPU) |
| `examples/effects/pixelize-transition`, `zoom-transition`, `fade-grays`, `blinds` | `xfade`-style transitions: pixel break-up, zoom, through grayscale, blinds |
| `examples/effects/falling-maple`, `falling-ginkgo` | Falling red maple / yellow ginkgo leaves: **PNG images in the package** (2×2 atlas), stateless particles (depend only on `t`, so seeking is correct), `var<workgroup>` + `workgroupBarrier`, 4 motion styles (`mode`). Source images and licenses are in `assets/leaves/` |
