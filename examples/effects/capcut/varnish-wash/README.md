# Varnish Wash

A burst of glossy liquid blobs sprays out of a point and merges into a metallic pool that shows the second clip, refracted and lit by a turning highlight, over the first clip. Drive `progress` from 0 to 1.

Recreates the CapCut "Varnish Wash" transition (99 metaballs from one emitter, a height field shaded as metal with a distant light). CapCut's default length for it is about 1.47 s, so drive `progress` over roughly that long, e.g. `progress=clip((t-1)/1.47\,0\,1)`. The blob layout comes from a chaotic hash chain, so individual blobs land in slightly different places than in CapCut; size, timing and look match.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `varnish-wash.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='varnish-wash.zip=progress=clip((t-1)/1.47\,0\,1)',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='varnish-wash.zip=progress=clip((t-1)/1.47\,0\,1)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'varnish-wash.zip=progress=0.5' -i a.png -i b.png -o out.png
```
