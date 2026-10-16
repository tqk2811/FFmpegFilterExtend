# Fit Picture

Fits the second input into the frame of the first, like the screen modes of slideshow tools: center, crop, stretch, or centered over a blurred copy. The first input gives the size, and shows through wherever the picture and `color` are transparent.

## Inputs

- `canvas`: Gives the output size and frame rate; shows through a transparent background
- `src`: Picture to fit, any size

No size constraint between the inputs.

## Output

Same size as the first input (`canvas`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `fit.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `mode` | int | `3` | 0 to 3 | 0 center, 1 crop to fill, 2 stretch, 3 center over a blurred stretched copy |
| `upscale` | bool | `false` | - | Let center and blur modes enlarge pictures smaller than the frame |
| `blur` | float | `0.14` | 0 to 0.5 | Blur radius of the background in mode 3, relative to the frame height |
| `color` | color | `#000000` | - | Background behind the picture in modes 0 to 2 (transparent shows the first input); mode 3 uses the blurred copy |

A `color` is `#rrggbb`.

A `bool` is `0`/`1` or `true`/`false`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i canvas.mp4 -i photo.png -filter_complex \
  "[0][1]gpufx=effect='fit.zip=mode=3&blur=0.14',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i canvas.mp4 -i photo.png -filter_complex \
  "[0][1]gpufx=effect='fit.zip=mode=3&blur=0.14',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

## Notes

Two passes: the first blurs a stretched copy of `src` along x; the second blurs along y and composes the picture over it. `canvas` is only used for its size and as the backdrop.
