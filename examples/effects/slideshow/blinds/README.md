# Blinds

Venetian blinds: stripes of the second clip widen until they cover the first. Drive `progress` from 0 to 1.

## Inputs

- `first`: Outgoing clip
- `second`: Incoming clip (same size as the first) (must have the same size as the first input)

## Output

Same size as the first input (`first`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `blinds.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](../../../../README.md) and [EFFECT_FORMAT](../../../../docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `progress` | float | `0.5` | 0 to 1 | 0 = first clip, 1 = second clip |
| `count` | int | `10` | 1 to 200 | Number of stripes |
| `vertical` | bool | `false` | | Vertical stripes instead of horizontal |
| `softness` | float | `0.05` | 0 to 0.5 | Edge width, relative to a stripe |
| `origin` | int | `0` | 0 to 1 | 0 = each stripe opens from one edge, 1 = from its center towards both edges |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=effect='blinds.zip=progress=clip((t-1)/1.5\,0\,1)&count=8&origin=1',hwdownload,format=yuv420p" out.mp4
```

Still pictures with the CLI:

```sh
./target/release/gpufx run 'examples/effects/slideshow/blinds=progress=0.5:count=8:origin=1' -i a.png -i b.png -o out.png
```

## Notes

`origin=0` is the `xfade`-style blinds (and the `bars_*_one` scripts of tanersener/ffmpeg-video-slideshow-scripts); `origin=1` matches the `bars_*_two` scripts, where every bar opens from its middle. The progress is linear.
