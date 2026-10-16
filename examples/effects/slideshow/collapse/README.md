# Collapse

The first clip shrinks into the center and uncovers the second. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (same size as the first) (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `collapse.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../../README.md) and [EFFECT_FORMAT](../../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `mode` | int | `0` | 0 to 3 | 0 = horizontal (closes/opens from the left and right edges), 1 = vertical (top and bottom), 2 = both (box), 3 = circle |
| `softness` | float | `0.005` | 0 to 0.25 | Edge width |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='collapse.zip=progress=clip((t-1)/1.5\,0\,1)&mode=3',hwdownload,format=yuv420p" out.mp4
```

## Notes

`mode` and `softness` are the same as in `expand`. Collapse shrinks a region of the first clip into the centre; expand grows a region of the second clip out of it.
