# Box In

The first clip zooms out into a box, the box slides out of the frame, a box of the second clip slides in from the same side and zooms in to fill the frame. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `box-in.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `direction` | int | `0` | 0 to 3 | Where the second box moves as it comes in: 0 left, 1 right, 2 up, 3 down (the first box leaves the opposite way, towards the side the second comes from) |
| `box` | float | `0.5` | 0.1 to 1 | Box size relative to the frame |
| `color` | color | `#000000` | RGB | Background around the boxes |

A `color` is `#rrggbb`.

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='box-in.zip=progress=clip((t-1)/2\,0\,1)&direction=0&color=#202020',hwdownload,format=yuv420p" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='box-in.zip=progress=clip((t-1)/2\,0\,1)&direction=0&color=#202020',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

Still pictures with the CLI:

```sh
./target/release/gpufx run 'examples/effects/slideshow/box-in=progress=0.375:direction=2' -i a.png -i b.png -o out.png
```

## Notes

After `box_in_horizontal.sh` and `box_in_vertical.sh` of [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts). The four phases take a quarter of `progress` each: zoom out (0 to 0.25), slide out (to 0.5), slide in (to 0.75), zoom in (to 1). The boxes move a whole frame, so at `progress` 0.5 the frame is the background color only. The first box leaves towards the side the second comes from, as in the scripts. Script `DIRECTION` 2 of the horizontal script (right to left) is `direction=0`, 1 is `direction=1`; in the vertical script 1 (top to bottom) is `direction=3` and 2 is `direction=2`. The box keeps the frame's aspect ratio. The motion is linear; the script's `zoompan` reaches the full zoom slightly before the end of its phase (0.04 per frame), here the zoom spans the whole quarter. The script turns one picture into five segments of a slideshow; here one `progress` runs the outgoing half of one clip and the incoming half of the next.
