# Push Film

Both clips run through a film strip: the second pushes the first out of the frame like a film moving through a projector. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (same size as the first) (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `push-film.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../../README.md) and [EFFECT_FORMAT](../../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `direction` | int | `0` | 0 to 3 | Where the clips move: 0 left, 1 right, 2 up, 3 down |
| `strip` | float | `0.1` | 0 to 0.3 | Width of the perforated band on each side, relative to the frame |
| `gap` | float | `0.03` | 0 to 0.2 | Gap between two pictures of the strip, relative to the frame |
| `holes` | int | `8` | 1 to 64 | Perforations per picture on each side |
| `film_color` | color | `#141414` | - | Colour of the film |
| `hole_color` | color | `#f2f2f2` | - | Colour seen through the perforations |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='push-film.zip=progress=clip((t-1)/1.5\,0\,1)&direction=0&holes=10',hwdownload,format=yuv420p" out.mp4
```
