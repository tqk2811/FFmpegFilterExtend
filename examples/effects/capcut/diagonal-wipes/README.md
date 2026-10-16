# Diagonal Wipes

Three diagonal strips switch from the first clip to the second one after another (bottom-left, middle, top-right). Each strip zooms into the first clip, swaps to the second clip zoomed in and settles back to full size, while streak blurs run along the diagonal and the whole frame shakes and punches in. Drive `progress` from 0 to 1.

Recreates the CapCut "Diagonal Wipes" transition. Recommended duration: 0.8 s (the CapCut default), e.g. `progress=clip((t-1)/0.8\,0\,1)&duration=0.8`.

**Set `duration` to the real transition length in seconds** (the same length the `progress` expression spans): the shake wobbles in real time, so a wrong `duration` makes it too fast or too slow.

**Tuning notes:** the strip boundaries (`EDGE`) were measured on the demo clip, and the stacked streak blurs are folded into one wider blur per strip instead of being run one after another.

## Animate mode

CapCut keeps the shake clock at 0 while it renders this transition, so in its export the frame sits at one fixed shaken offset; only the shake amplitude and the punch-in zoom swell and fade with `progress`. `animate=false` reproduces that. `animate=true` (the default) lets the shake wobble in real time over `duration`.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `diagonal-wipes.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `duration` | float | `0.8` | 0.01 to 10 | Real transition length in seconds; must match the `progress` span. Sets the speed of the shake |
| `animate` | bool | `true` | | `true` = the shake wobbles over `duration`; `false` = frozen at t = 0 like CapCut's export |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='diagonal-wipes.zip=progress=clip((t-1)/0.8\,0\,1)&duration=0.8',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='diagonal-wipes.zip=progress=clip((t-1)/0.8\,0\,1)&duration=0.8',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'diagonal-wipes.zip=progress=0.5:duration=0.8' -i a.png -i b.png -o out.png
```
