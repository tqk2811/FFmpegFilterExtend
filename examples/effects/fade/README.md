# Fade

Fade to or from a color. Drive `progress` from 0 to 1.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `fade.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../README.md) and [EFFECT_FORMAT](../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0` | 0 to 1 | 0 = video, 1 = color |
| `color` | color | `#000000` | - | Target color |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=effect='fade.zip=progress=clip(t/2\,0\,1)&color=#000000',hwdownload,format=nv12" out.mp4
```

## Notes

A single input: `progress` 1 is the solid colour. To fade in from the colour, drive `progress` from 1 down to 0, for example `1-clip(t/2\,0\,1)`. The colour's alpha scales the fade.
