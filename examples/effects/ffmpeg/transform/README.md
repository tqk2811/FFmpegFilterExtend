# Transform

Zoom, rotate and pan (Ken Burns style when driven by expressions).

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `transform.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../../README.md) and [EFFECT_FORMAT](../../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `zoom` | float | `1` | 0.01 to 100 | 1 = unchanged, 2 = twice as big |
| `angle` | float | `0` | - | Rotation in degrees, clockwise |
| `center` | vec2 | `0.5, 0.5` | - | Point of the source shown at the frame center (0..1) |
| `background` | color | `#000000` | - | Fill outside the source |

A `vec2` is two comma-separated numbers (`center=0.3,0.6`; write `0.3\,0.6` in an FFmpeg command line).

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=effect='transform.zip=zoom=1+0.05*t&angle=2*t&center=0.5\,0.5',hwdownload,format=nv12" out.mp4
```

## Notes

Driving `zoom` and `center` with expressions gives a Ken Burns move.
