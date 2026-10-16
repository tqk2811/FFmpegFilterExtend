# Ripple Vibe

The picture shakes with motion blur, flares bright and ripples sideways in noisy horizontal waves, cutting from the first clip to the second at the midpoint (CapCut "Ripple Vibe"). Drive `progress` from 0 to 1.

Recreated from the CapCut transition of the same name; CapCut's default length for it is about 0.8 s, so drive `progress` over roughly that long.

**Set `duration` to the real transition length in seconds** (the same length the `progress` expression spans): the shake and the ripples move in real time, so a wrong `duration` makes them too fast or too slow.

**Tuning notes:** these constants were fitted to the demo clip, not taken from CapCut's source: the shake blur window is widened to +-1/30 s (`shaders/shake.wgsl` lines 60-62), and the shake time origin is assumed to be `t = progress * duration`.

## Animate mode

CapCut keeps the shake and ripple clock at 0 while it renders this transition, so in its export the picture sits at one fixed shaken position and the ripple pattern does not travel; only the ripple amplitude and the exposure flash swell and fade with `progress`. `animate=false` reproduces that frame for frame. `animate=true` (the default) lets the shake and the ripples move in real time over `duration`, which looks livelier.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `ripple-vibe.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `duration` | float | `0.8` | 0.01 to 10 | Real transition length in seconds; must match the `progress` span. Sets the speed of the shake and the ripples |
| `animate` | bool | `true` | | `true` = the shake and the ripples move over `duration`; `false` = frozen at t = 0 like CapCut's export |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='ripple-vibe.zip=progress=clip((t-1)/0.8\,0\,1)&duration=0.8',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='ripple-vibe.zip=progress=clip((t-1)/0.8\,0\,1)&duration=0.8',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'ripple-vibe.zip=progress=0.5' -i a.png -i b.png -o out.png
```
