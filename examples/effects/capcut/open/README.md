# Open

The first clip splits down the middle and both halves swing open in perspective while the second clip comes forward from the distance over a floor reflection. Drive `progress` from 0 to 1.

Recreates the CapCut "Open" transition (a doorway: reflection 0.4, perspective 0.4, depth 3). Recommended duration: 0.8 s (the CapCut default), e.g. `progress=clip((t-1)/0.8\,0\,1)`.

## Overlap mode

CapCut does not blend the two clips for this transition: it feeds the effect the first clip in both roles while `progress` is below 0.5, and the second clip in both roles from 0.5 on. `overlap=false` (the default) reproduces that, so the output matches CapCut frame for frame, with a jump at the midpoint where the source switches. `overlap=true` uses the first clip as the outgoing picture and the second as the incoming one all the way through, so the doors open onto the second clip.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `open.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `overlap` | bool | `false` | | false = like CapCut: one clip in both roles per half (first, then second); true = blend the first clip into the second |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='open.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='open.zip=progress=clip((t-1)/0.8\,0\,1)',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

With the `gpufx` CLI on two PNGs:

```sh
gpufx run 'open.zip=progress=0.5' -i a.png -i b.png -o out.png
```
