# Gaussian Blur

Separable gaussian blur in two passes.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `gaussian-blur.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../../README.md) and [EFFECT_FORMAT](../../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `radius` | float | `6` | 0 to 48 | Blur radius in pixels |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=effect='gaussian-blur.zip=radius=12',hwdownload,format=nv12" out.mp4
```

With the `gpufx` CLI on a PNG:

```sh
gpufx run 'gaussian-blur.zip=radius=12' -i in.png -o out.png
```

## Notes

Two passes (horizontal, then vertical) through an intermediate texture.
