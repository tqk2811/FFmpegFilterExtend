Tiếng Việt: [EFFECT_FORMAT-vi.md](EFFECT_FORMAT-vi.md)

# Effect package format and how to write shaders (api 2)

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
gpufx run 'my-effect=strength=0.8' -i in.png -o out.png
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
| `api` | number | no (1) | Format version. `2` is needed for texture arrays, `mipmaps`, `premultiply` and `expr` parameters; packages without those keep `1` and run as before. A runtime older than the package says `unsupported manifest api 2` |
| `id` | string | yes | Identifier in reverse-DNS form |
| `name` | string | yes | Display name |
| `version`, `description` | string | no | |
| `inputs` | array | no (`[{"name":"src"}]`) | The video inputs, in the filter's pad order, with their rules (see below) |
| `output` | `{formats}` | no (`rgba` and every format converted on the GPU) | Allowed output pixel formats |
| `params` | array | no | Parameters, see below |
| `textures` | array | no | Bundled PNG images (LUT, mask, sprites), see [Textures](#textures) |
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
| `mipmaps` | `false` | (api 2) The input texture gets a full mip chain, made on the GPU every frame, for shaders that shrink it a lot (`textureSampleLevel(src, smp, uv, lod)`); see [Mipmaps](#mipmaps) |

`output.formats`: the allowed output pixel formats, in order of preference. Without `output` the list is
`rgba`, `rgba64le`, `nv12`, `p010le`, `yuv420p`, `yuv422p`, `yuv444p`, `yuv420p10le`, `yuv422p10le`,
`yuv444p10le`, `yuva420p`, `yuva444p`: the formats gpufx writes on the GPU. So an effect without
`output.formats` may output YUV without alpha: the alpha it writes is dropped unless the filter after it
takes an alpha format. **An effect that produces alpha should declare `output.formats`** (e.g.
`["rgba", "yuva420p"]`). FFmpeg
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

- **FFmpeg:** an input without `formats` takes the formats gpufx converts on the GPU (the list above, plus
  `yuvj420p`/`yuvj422p`/`yuvj444p`); FFmpeg converts other formats to one of them. An input with
  `formats` receives the stream's format as is; if it is not in the list, configuring the filter graph fails.
  To make it work, change the format first with `format=yuv420p,gpufx=...`. The size is checked
  at configuration and whenever the frame size changes. A misspelled format name is also an error.
- **Chains and graphs** (`effect='a|b'`, `graph='...'`): every effect is checked where it sits. An effect
  reading another sees that effect's size (the size of its first input) and the first format of its
  `output.formats` that the reader accepts; an input pad read by several effects must have a format
  all of them accept. `same_size` therefore also holds between two branches of a graph.
- **`gpufx run`:** the format comes from the PNG (`rgba`, `rgb24`, `gray`, `ya8`, and the 16-bit versions
  `rgba64be`, `rgb48be`, `gray16be`, `ya16be`). The CLI always writes an RGBA PNG, so it does not check
  `output.formats`.
- Shaders always see RGBA with straight alpha, whatever the input/output format is: the conversion happens
  on the GPU outside the shader. The textures are `rgba8unorm`, or `rgba16float` when an input or the
  output of the chain has more than 8 bits (10-bit video keeps its precision).

Each element of `params`:

| Field | Meaning |
|-------|---------|
| `name` | Name, also the field name in `params.<name>` |
| `type` | `float`, `int`, `bool`, `vec2`, `vec3`, `vec4`, `color`, `expr` (api 2) |
| `default` | A number, an array of numbers, `true/false`, or a string (`"#ff8800"`; the expression of an `expr`) |
| `min`, `max` | The value is clamped to this range (not for `expr`) |
| `vars` | `expr` only: the variable names of the expression, in the order of the shader function's arguments |
| `description` | Description |

Types in the shader: `float`→`f32`/`float`, `int`→`i32`/`int`, `bool`→`u32`/`uint` (0 or 1),
`vecN`→`vecNf`/`vecN`, `color`→`vec4f`/`vec4` (RGBA 0..1). An `expr` is not in `params`: it becomes a
function, see [Expression parameters](#expression-parameters).

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
A param must not be named `enable` or `bypass`: the inline keys `enable=` and `bypass=` of an effect (`effect='my-effect.zip=enable=lt(t\,2)'`) switch an effect of a chain or graph.

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
@group(0) @binding(2) var out_tex: texture_storage_2d<rgba8unorm, write>; // rgba16float above 8 bits
@group(0) @binding(3) var smp: sampler;
@group(0) @binding(4) var src: texture_2d<f32>;
// A texture with `layers` or `grid` is a texture_2d_array<f32> (GLSL: texture2DArray).
// An `expr` parameter adds fn gpufx_expr_<name>(<vars>: f32...) -> f32.
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
- Colors are RGBA 0..1 (8-bit or half float), with no gamma conversion (sRGB values as in the video).
  Always write through `gpufx_write`: the storage format of `out_tex` depends on the frames (in GLSL the
  prelude declares it `rgba8` or `rgba16f`).

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

## Textures

Each element of `textures` makes one read-only `rgba8unorm` texture from PNG files in the package, bound
under its `name` (it must not collide with an input, a pass output or another texture):

```json
"api": 2,
"textures": [
  { "name": "lut", "path": "textures/lut.png" },
  { "name": "leaves", "layers": ["textures/maple.png", "textures/oak.png"], "mipmaps": true, "premultiply": true },
  { "name": "petals", "path": "textures/petals.png", "grid": [4, 2], "count": 7, "mipmaps": true, "premultiply": true }
]
```

| Field | Default | Meaning |
|-------|---------|---------|
| `name` | | Name in the shader |
| `path` | | One PNG. Without `grid` it is a `texture_2d<f32>` (api 1) |
| `layers` | | (api 2) PNGs **of one size**, the layers of a `texture_2d_array<f32>`, in order |
| `grid` | | (api 2) `[cols, rows]` with `path`: cuts an atlas into the layers of a `texture_2d_array<f32>`, row by row. The width and height must divide exactly |
| `count` | `cols*rows` | (api 2) Cells of the grid to use, when the last ones are empty |
| `mipmaps` | `false` | (api 2) Make the full mip chain on the CPU when the package loads (each level from the one above, triangle filter, after `premultiply`) |
| `premultiply` | `false` | (api 2) Multiply RGB by alpha when loading: the shader reads premultiplied colours |

Rules: exactly one of `path`/`layers`; `grid` only with `path`, `count` only with `grid`; 1 to 256 layers;
each image at most **4096** pixels a side (also below what the device allows; the runtime checks
`max_texture_dimension_2d` and `max_texture_array_layers` and reports an error instead of letting wgpu
abort the process); all images of a package decode to at most **64 M texels** (256 MiB RGBA8). The sizes
come from the PNG headers when the package opens (`gpufx check` reports them), and the decoder is capped,
so a small file claiming a huge image is refused before any memory is spent.

Loading happens once per package and device, on the CPU: the decoded images, their cut layers and
mip chains (a third more) are all held until the upload, so the peak is about twice the decoded size
(up to some 700 MiB for a package at the 64 M texel limit). 16-bit PNGs are decoded at 16 bits (twice
the bytes, which counts against the decoder cap of 256 MiB per image) and then reduced to 8 bits: package
textures are always `rgba8unorm`. Mip levels are filtered with premultiplied alpha even when
`premultiply` is off (and divided back), so transparent texels do not darken the edges.

Texture arrays are read with a layer index, which may differ from pixel to pixel:

```wgsl
let n = textureNumLayers(leaves);                              // layers
let c = textureSampleLevel(leaves, smp, uv, layer, lod);       // layer: u32 or i32
let d = textureLoad(leaves, vec2i(x, y), layer, 0);
```
```glsl
vec4 c = textureLod(sampler2DArray(leaves, smp), vec3(uv, layer), lod);
```

Every layer is clamped at its own edge: unlike an atlas sampled by hand, filtering and mip levels never
bleed in the neighbouring picture.

**Alpha.** PNG colours are straight alpha, and transparent pixels usually have RGB = 0: filtering them
(bilinear, mip levels) darkens the edges of sprites. With `premultiply: true` the texture holds
premultiplied colours and filters correctly; blend with `acc = c + acc * (1 - c.a)` and divide by alpha
before `gpufx_write` (which takes straight alpha). It is off by default so LUTs and masks keep their
values.

**Colour.** Texture values are taken as having the transfer of the video (sRGB/BT.709 gamma), with no
conversion, like the rest of the engine. When the pipeline moves to linear light, a `colorspace` field
will say how to convert them.

### Mipmaps

The shared sampler `smp` filters linearly between mip levels (`mipmap_filter: Linear`); textures with
one level sample exactly as before. Compute shaders have no derivatives, so the shader chooses the level
itself: `lod = log2(texels across / pixels across on screen)`, e.g. once per sprite rather than per
pixel. Without mip levels, a picture drawn much smaller than it is flickers and looks jagged.

Inputs can have mip levels too (`"mipmaps": true` in `inputs`): the chain is made on the GPU right after
the input is converted, or after the effect that writes it in a chain or graph, every frame, inside the
frame texture itself (a third more memory for that texture, no copy). Effects reading the same frame
without `mipmaps` see level 0 only. Levels are the alpha-weighted average of 2×2 texels. Use it when an
effect shrinks a picture a lot (a 4000 px photo in a small box).

## Sprites and particles

`falling-maple`/`falling-ginkgo` draw up to 256 sprites in one compute pass. The pattern:

- **Stateless:** every particle is a pure function of `(seed, slot, time)`. A slot replays a fixed
  period; a new period is a new random particle ("respawn"), chosen while it is off screen. Seeking,
  dropped or repeated frames and split encodes then all give the same picture. Use `globals.time_int` and
  `time_frac` (or `time`), **never `globals.frame`**: it is counted per filter and restarts on seek.
  `-ss` before `-i` (without `-copyts`) resets the time to 0; an `offset` parameter helps.
- **Workgroup cache:** the 64 threads of a workgroup compute the particles once into
  `var<workgroup> leaves: array<Leaf, 256>` (here 40 bytes each: keep it under the 16 KiB default
  limit), then `workgroupBarrier()`. The barrier must be reached in **uniform control flow**: call
  `gpufx_in_bounds` *after* it, not before.
- **Per pixel:** skip particles whose bounding circle misses the pixel, map the pixel into sprite space,
  sample the texture array with the level computed per sprite, blend premultiplied.
- **Parameters that set the period** (`speed`, `wind`, `size`, `count`, `life`) should not be FFmpeg
  expressions of `t`: positions are `f(t * speed)`, not an integral of the speed, so every particle
  would jump. `opacity` and `seed` can follow `t`.
- Positions computed with `sin`/`cos` in f32 differ below a pixel between GPUs; on one machine the
  output is identical byte for byte.

## Expression parameters

An `expr` parameter (api 2) holds a math expression, given as text like any parameter (inline after the package name in `effect=`/`graph=` of the
filter, `sendcmd`, inline in `gpufx run`), and evaluated on the GPU wherever the shader calls it, for example
once per particle:

```json
{ "name": "path_x", "type": "expr", "vars": ["u", "p", "x0"], "default": "x0 + 0.05*sin(tau*u)" }
```

```wgsl
let x = gpufx_expr_path_x(u, p, x0);   // the arguments in the order of `vars`, all f32
```

- The text may hold numbers (`1`, `0.5`, `2e-3`), the declared variables, the constants `pi`, `tau`,
  `e`, `+ - * /`, `^` (power), parentheses and the functions `sin cos tan asin acos atan atan2 abs sign
  min max clamp mix step smoothstep pow sqrt exp log floor ceil round fract`. Nothing else: the text is
  parsed into a tree and the shader code is generated from the tree, never pasted. At most 1024 bytes,
  512 terms, 32 levels of nesting.
- The function returns an `f32`. NaN and infinities (`log(-1)`, `1/0`) come out as **0**, so a shader
  never sees them (a particle at 0 may still be on screen: pick formulas that stay defined).
- Variable names are plain identifiers: a letter first, no `__`.
- A new expression rebuilds the effect's pipelines (a few milliseconds): change it now and then
  (`sendcmd`), not every frame. It is compiled when it is set, so a text that does not parse or compile
  is an error there (`sendcmd` reports it) and the last good expression stays; the stream goes on.
  The default expressions use the pipelines shared by every effect opened from the package.
- On the FFmpeg command line, commas inside the quoted `effect='...'`/`graph='...'` are escaped as for any filter option, and
  inline keys are separated by `&` (no escaping needed): `effect='x.zip=angle=max(90*u\,0)&speed=2'`. The
  FFmpeg-style `:` is also accepted but must be written `\:` there (`...\,0)\:speed=2`). In the effect string
  `\&` is a literal `&` (escapable set: `\ ' : & ; | = [ ]`).

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
| `examples/effects/checkerboard`, `push-box`, `push-film`, `photo-collection` | Slideshow transitions after [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts) (written anew as shaders): growing squares, shrink-push-grow boxes, a procedural perforated film strip, a photo that flies in spinning and lands tilted on the first clip (chain it to stack photos) |
| `examples/effects/sliding-bars`, `spin-transition` | From the same scripts: bars of the second clip slide in one after another (`stagger`), the first clip spins out shrinking and the second spins in growing with motion blur (a loop of samples along the angle). `slide-transition` also has a `mode` for push / cover / uncover / box in (a `color` background), `blinds` an `origin` to open from the middle of each bar |
| `examples/effects/fit` | The screen modes of those scripts (center, crop, stretch, blurred background) for a picture of any size: the first input only sets the frame; **two passes**, a separable box blur with a fixed number of bilinear taps |
| `examples/effects/falling-maple`, `falling-ginkgo` | Falling red maple / yellow ginkgo leaves (api 2): a 2×2 atlas cut into a **texture array** (`grid`) with **mipmaps** and **premultiplied alpha**, the mip level computed per leaf, stateless particles (depend only on `t`, so seeking is correct), `var<workgroup>` + `workgroupBarrier`, 4 motion styles (`mode`) and a custom path (`mode=4`, **`expr` parameters** `path_x`, `path_y`, `angle`). Source images and licenses are in `assets/leaves/` |
