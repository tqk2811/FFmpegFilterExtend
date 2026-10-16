# Soft Wipe

Transition from the first input to the second with a soft moving edge. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip

No size constraint between the inputs.

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `wipe-transition.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../README.md) and [EFFECT_FORMAT](../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `angle` | float | `0` | - | Wipe direction in degrees |
| `softness` | float | `0.15` | 0.001 to 1 | Edge width |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='wipe-transition.zip=progress=clip((t-1)/1.5\,0\,1)&angle=45&softness=0.2',hwdownload,format=yuv420p" out.mp4
```

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'wipe-transition.zip=progress=0.5:angle=45' -i in.png -i in.png -o out.png
```
