# Vignette

Darkens (or tints) the frame edges.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `vignette.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../../README.md) and [EFFECT_FORMAT](../../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `strength` | float | `0.6` | 0 to 1 | How strong the vignette is |
| `radius` | float | `0.75` | 0 to 1.5 | Where the darkening starts |
| `color` | color | `#000000` | - | Vignette color |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=effect='vignette.zip=strength=0.8&radius=0.7&color=#000000',hwdownload,format=nv12" out.mp4
```

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'vignette.zip=strength=0.9' -i in.png -o out.png
```
