# Sliding Bars

Bars of the second clip slide in over the first one after another. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (same size as the first) (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `sliding-bars.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../../README.md) and [EFFECT_FORMAT](../../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `count` | int | `5` | 1 to 100 | Number of bars |
| `vertical` | bool | `false` | | Vertical bars sliding down/up instead of horizontal bars sliding right/left |
| `direction` | int | `0` | 0 to 1 | 0 = bars come in from the left (top when vertical), 1 = from the right (bottom) |
| `stagger` | float | `1` | 0 to 1 | 1 = each bar starts when the previous one lands, 0 = all bars move together |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='sliding-bars.zip=progress=clip((t-1)/1.5\,0\,1)&count=6&direction=1',hwdownload,format=yuv420p" out.mp4
```

Still pictures with the CLI:

```sh
./target/release/gpufx run 'examples/effects/slideshow/sliding-bars=progress=0.5:count=6:direction=1' -i a.png -i b.png -o out.png
```

## Notes

After the `sliding_bars_*` scripts of [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts). Bars start in order from the top (left when vertical). Every bar slides for the same share of `progress` and the last one lands exactly at 1; with `stagger` between 0 and 1 the bars overlap in time. The motion is linear.
