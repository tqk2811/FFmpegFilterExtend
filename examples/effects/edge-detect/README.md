# Edge Detect

Sobel edges, optionally drawn over the original.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `edge-detect.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../README.md) and [EFFECT_FORMAT](../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `strength` | float | `1` | 0 to 10 | Edge gain |
| `blend` | float | `1` | 0 to 1 | 0 = original, 1 = edges only |
| `color` | color | `#ffffff` | - | Edge color |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=effect='edge-detect.zip=strength=2&blend=1&color=#00ffff',hwdownload,format=nv12" out.mp4
```

## Notes

Edges come from a 3x3 Sobel kernel on luma; the edge colour is scaled by the edge strength.
