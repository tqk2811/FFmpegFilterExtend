# Sideway Bounce

The picture zooms in and is knocked sideways by a fading wobble, smeared along the wobble path, while a bright glow builds up and a faint band of light rises up the frame; the picture cuts to the second clip at the peak and settles back. Drive `progress` from 0 to 1.

Recreates the CapCut "Sideway Bounce" transition (zoom to 1/0.72, wobble 192 px on a 1080 px short side, glow above 0.5 at up to 3x). CapCut's default length for it is about 0.8 s, so drive `progress` over roughly that long, e.g. `progress=clip((t-1)/0.8\,0\,1)`. `duration` should match the real length the progress is driven over. The wobble runs on real time: set `duration` to the real length of the transition so it moves at the intended speed (CapCut's own exports freeze this clock, so there the picture is offset but does not wobble; `duration=0` reproduces that). The light band is drawn procedurally.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `sideway-bounce.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `duration` | float | `0.8` | 0 to 10 | Real length of the transition in seconds; sets the speed of the wobble (0 freezes it, like CapCut exports) |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='sideway-bounce.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='sideway-bounce.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'sideway-bounce.zip=progress=0.5' -i a.png -i b.png -o out.png
```
