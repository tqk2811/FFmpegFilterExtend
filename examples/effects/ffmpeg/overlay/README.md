# Picture in Picture

Draws the second input over the first, scaled and positioned, honouring its alpha.

## Inputs

- `base`: Background video
- `top`: Video drawn on top (alpha is honoured)

No size constraint between the inputs.

## Output

Same size as the first input (`base`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `overlay.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `x` | float | `0.65` | -1 to 2 | Left edge of the overlay, 0..1 of the frame width |
| `y` | float | `0.05` | -1 to 2 | Top edge of the overlay, 0..1 of the frame height |
| `scale` | float | `0.3` | 0.01 to 1 | Overlay width relative to the frame width |
| `opacity` | float | `1` | 0 to 1 | Overlay opacity |
| `border` | float | `0` | 0 to 50 | Border width in pixels |
| `border_color` | color | `#ffffff` | - | Border color |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i base.mp4 -i pip.mp4 -filter_complex \
  "[0][1]gpufx=effect='overlay.zip=x=0.65&y=0.05&scale=0.3&border=3',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i base.mp4 -i pip.mp4 -filter_complex \
  "[0][1]gpufx=effect='overlay.zip=x=0.65&y=0.05&scale=0.3&border=3',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

## Notes

The overlay keeps its own aspect ratio; only its width is set (`scale`). It may reach outside the frame (`x`, `y` accept -1 to 2).
