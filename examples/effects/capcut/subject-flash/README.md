# Subject Flash

The first clip twists away about its vertical axis while it blows out into glowing round bokeh, then the second clip twists back in out of the same glare. Drive `progress` from 0 to 1.

Recreated from the CapCut transition of the same name; CapCut's default length for it is about 0.8 s, so drive `progress` over roughly that long.

CapCut keys this transition on a longer internal timeline and stretches it over the transition length, so `progress` 0 to 1 covers the whole of it. The twist, glare and bokeh all happen in the middle, between `progress` 0.38 and 0.62; before and after that the clips only carry a faint glow on their brightest parts, which fades in over the first 7 % and out over the last 7 % so the ends match the plain clips.

The picture switches from the first clip to the second at the midpoint, hidden in the glare, so drive `progress` smoothly at the video frame rate.

CapCut also lays an AI subject cut-out (person segmentation) of each clip over the glare and flashes it to white around the switch. gpufx has no segmentation input, so that layer is left out: the twist, glow and bokeh carry the flash on their own. With the demo footage (landscapes) the result matches CapCut's export closely; on footage with a clear person the CapCut version additionally shows that person's silhouette flashing white.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `subject-flash.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='subject-flash.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='subject-flash.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'subject-flash.zip=progress=0.5' -i a.png -i b.png -o out.png
```
