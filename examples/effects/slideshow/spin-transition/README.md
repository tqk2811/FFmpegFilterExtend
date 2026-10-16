# Spin

The first clip spins out shrinking, then the second spins in growing, with motion blur. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `spin-transition.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `turns` | float | `1` | 0 to 10 | Turns made by each clip during its half of the transition, rounded to the nearest half turn (below 0.25 rounds to 0: no spin) |
| `zoom` | float | `1` | 0 to 1 | How much the clips shrink at the middle: 1 = to nothing, 0 = not at all |
| `blur` | int | `8` | 1 to 32 | Motion-blur samples along the rotation (1 = no blur) |
| `color` | color | `#000000` | RGB | Background around the spinning clip |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='spin-transition.zip=progress=clip((t-1)/1.5\,0\,1)&turns=2&blur=12',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='spin-transition.zip=progress=clip((t-1)/1.5\,0\,1)&turns=2&blur=12',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

Still pictures with the CLI:

```sh
./target/release/gpufx run 'examples/effects/slideshow/spin-transition=progress=0.5:turns=2:blur=12' -i a.png -i b.png -o out.png
```

## Notes

After `spin_blur_rotation.sh` of [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts). The first half (`progress` < 0.5) shows only the first clip, the second half only the second; both turn the same way. The rotation is pixel-correct for any aspect ratio. The blur spread grows with the rotation and is zero at both ends, so `progress` 0 and 1 show the clips unchanged; with `zoom=1` the frame at 0.5 is the background color only. The cost grows with `blur` (one texture sample per step). `turns` is rounded to the nearest half turn: the first clip ends its half at +`turns` and the second starts at -`turns`, which is the same angle only for whole half turns, so the rotation stays continuous at `progress` 0.5 (when `zoom` < 1 leaves the clip visible) and starts and ends upright. The blur is angular (samples spread along the rotation), unlike the `boxblur` of the script.
