# Chroma Key

Removes a key color (green screen) into alpha. Use a format with alpha after it, or overlay it.

## Inputs

- `src` (accepted pixel formats: `yuv420p`, `yuv422p`, `yuv444p`, `yuvj420p`, `nv12`, `rgb24`, `bgr24`, `rgba`, `bgra`)

## Output

Same size as the first input (`src`). Pixel format: one of `rgba`, `yuva420p`, `yuva444p`.

## Options

Written inline after the package name: `chroma-key.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../README.md) and [EFFECT_FORMAT](../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `key` | color | `#00ff00` | - | Color to remove |
| `similarity` | float | `0.25` | 0 to 1 | How close to the key a color must be to become transparent |
| `smoothness` | float | `0.08` | 0 to 1 | Width of the soft edge |
| `spill` | float | `0.5` | 0 to 1 | Removes the key tint from the remaining edges |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i greenscreen.mp4 -i bg.mp4 -filter_complex \
  "[0][1]gpufx=graph='[0]chroma-key.zip=similarity=0.3&smoothness=0.1[k]; [1][k]overlay.zip=x=0&y=0&scale=1[out]',hwdownload,format=yuv420p" out.mp4
```

## Notes

The output carries alpha. A filter after it must take an alpha format (`rgba`, `yuva420p`, `yuva444p`) to keep it; `overlay.zip` honours it. Converting to a format without alpha drops it.
