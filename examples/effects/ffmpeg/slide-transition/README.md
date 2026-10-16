# Slide

The second clip slides into the frame: it pushes the first out, covers it, uncovers it or pushes it through a gap of `color` (`mode`). Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `slide-transition.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `direction` | int | `0` | 0 to 3 | 0 = left, 1 = right, 2 = up, 3 = down |
| `mode` | int | `0` | 0 to 3 | 0 = push (the second clip pushes the first out), 1 = cover (the second slides in over the still first), 2 = uncover (the first slides out over the still second), 3 = push through color (the first is pushed out, a gap of `color`, then the second is pushed in) |
| `color` | color | `#000000` | RGB | Background between the clips in mode 3 |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='slide-transition.zip=progress=clip((t-1)/1.5\,0\,1)&mode=3&color=#202020',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='slide-transition.zip=progress=clip((t-1)/1.5\,0\,1)&mode=3&color=#202020',hwdownload,format=yuv420p" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

Still pictures with the CLI:

```sh
./target/release/gpufx run 'examples/effects/ffmpeg/slide-transition=progress=0.5:mode=3' -i a.png -i b.png -o out.png
```

## Notes

The motion is eased (`smoothstep` of `progress`). Modes 0 to 2 follow the push, cover/wipe-in and wipe-out scripts of [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts). Mode 3 (push through color) moves full frames: the first clip is out of the frame exactly at `progress` 0.5, so the frame there is the background color only. For the look of the `box_in_*` scripts (zoom out into a box, slide, zoom in) use [box-in](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/examples/effects/slideshow/box-in/README.md). The default (`mode=0`) is the original push behaviour.
