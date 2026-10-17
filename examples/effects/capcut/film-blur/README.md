# Film Blur

A hard cut hidden under a burst of warm, high-contrast light leak (dark red to orange to yellow) screened over the picture, with a soft half-resolution, sideways-smeared and colour-graded film look throughout. Drive `progress` from 0 to 1.

Recreated from the CapCut transition of the same name; CapCut's default length for it is about 0.8 s, so drive `progress` over roughly that long. The film look (half-resolution softening, horizontal smear, colour grade) applies for the whole transition, as in CapCut, so the picture changes visibly at the first and last frame of the transition; `progress` 0 and 1 give the plain clips.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `film-blur.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='film-blur.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='film-blur.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'film-blur.zip=progress=0.5' -i a.png -i b.png -o out.png
```
