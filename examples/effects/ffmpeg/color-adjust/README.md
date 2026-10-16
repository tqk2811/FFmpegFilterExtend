# Color Adjust

Brightness, contrast, saturation, gamma, hue and white balance in one pass.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `color-adjust.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `brightness` | float | `0` | -1 to 1 | Added to every channel |
| `contrast` | float | `1` | 0 to 4 | 1 = unchanged |
| `saturation` | float | `1` | 0 to 4 | 0 = gray, 1 = unchanged |
| `gamma` | float | `1` | 0.1 to 10 | Values above 1 brighten mid tones |
| `hue` | float | `0` | -180 to 180 | Hue rotation in degrees |
| `temperature` | float | `0` | -1 to 1 | Negative = cooler (blue), positive = warmer (orange) |
| `tint` | float | `0` | -1 to 1 | Negative = green, positive = magenta |

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=effect='color-adjust.zip=contrast=1.2&saturation=1.3&temperature=0.1',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=effect='color-adjust.zip=contrast=1.2&saturation=1.3&temperature=0.1',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).
