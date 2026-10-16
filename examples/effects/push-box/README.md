# Push Box

The first clip shrinks into a box, the box is pushed out by a box of the second clip, which then grows to fill the frame. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (same size as the first) (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `push-box.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../README.md) and [EFFECT_FORMAT](../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `direction` | int | `0` | 0 to 3 | Where the clips move: 0 left, 1 right, 2 up, 3 down |
| `box` | float | `0.5` | 0.1 to 1 | Box size relative to the frame |
| `color` | color | `#000000` | - | Background around the boxes |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='push-box.zip=progress=clip((t-1)/1.5\,0\,1)&direction=2&box=0.5&color=#202020',hwdownload,format=yuv420p" out.mp4
```
