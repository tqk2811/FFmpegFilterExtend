# RGB Split + Grain

Chromatic aberration with animated film grain, written in GLSL.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `rgb-split.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../README.md) and [EFFECT_FORMAT](../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `amount` | float | `6` | 0 to 64 | Channel offset in pixels |
| `angle` | float | `0` | - | Offset direction in degrees |
| `grain` | float | `0.08` | 0 to 1 | Grain strength |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=effect='rgb-split.zip=amount=8&angle=45&grain=0.1',hwdownload,format=nv12" out.mp4
```

## Notes

Written in GLSL (`shaders/rgb_split.comp`); the grain is animated by the frame counter.
