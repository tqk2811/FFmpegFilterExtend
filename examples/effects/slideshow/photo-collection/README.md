# Photo Collection

The second clip flies in as a photo, spinning, and lands tilted on top of the first: chain it to stack photos. At `progress` 1 the photo lies on the first clip, so the result is not the second clip alone. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `photo-collection.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = the photo has landed on the first clip |
| `direction` | int | `0` | 0 to 3 | Where the photo comes from: 0 left, 1 right, 2 top, 3 bottom |
| `angle` | float | `12` | -180 to 180 | Tilt of the photo once it lands, in degrees |
| `spins` | float | `3` | -20 to 20 | Turns during the flight (negative: the other way) |
| `size` | float | `0.8` | 0.05 to 1 | Photo size, border included: it fits inside this part of the frame |
| `border` | float | `0` | 0 to 0.2 | Photo border, relative to the frame height |
| `border_color` | color | `#ffffff` | - | Border colour |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='photo-collection.zip=progress=clip((t-1)/1.5\,0\,1)&direction=1&angle=-8&border=0.02',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='photo-collection.zip=progress=clip((t-1)/1.5\,0\,1)&direction=1&angle=-8&border=0.02',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

## Notes

Chain several `photo-collection` effects to stack photos: at `progress` 1 the result is the first clip with the photo on top, which then feeds the next stage as its first input.
