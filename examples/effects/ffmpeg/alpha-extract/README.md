# Alpha extract

Alpha channel as a gray picture (a matte): white where opaque, black where transparent. Like FFmpeg's `alphaextract`, but on the GPU, inside a `gpufx` graph.

D3D12 and D3D11 frames from FFmpeg have no pixel format with alpha (`nv12` and `p010le` only), so an effect whose output has alpha loses it there. Split that output: one copy for the colors (fill), one through `alpha-extract` (matte), both `nv12`. Then join them on the CPU with `alphamerge` into a format with alpha, or keep two files and join them later. With Vulkan, `out_format=rgba` keeps the alpha directly and this package is not needed.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU. Without alpha the matte is all white.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule). The output alpha is 1.

## Options

Written inline after the package name: `alpha-extract.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `invert` | bool | `false` | - | White where transparent instead of where opaque |

## Example

Direct3D 12 (Windows): `push-box` with a transparent background, fill and matte written to two lossless files:

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i a.mp4 -i b.mp4 -filter_complex \
  "[0][1]gpufx=graph='[0][1]push-box.zip=progress=clip((t-1)/1.5\,0\,1)&color=#00000000[x]; [x]split[fill][m]; [m]alpha-extract.zip[matte]'[f][k];[f]hwdownload,format=nv12[f2];[k]hwdownload,format=nv12[k2]" \
  -map "[f2]" -c:v ffv1 fill.mkv -map "[k2]" -c:v ffv1 matte.mkv
```

Joined into a VP9 video with alpha (any FFmpeg build with `alphamerge`; `format=gray` also turns the matte's limited range into full range, so black is alpha 0):

```sh
ffmpeg -i fill.mkv -i matte.mkv -filter_complex "[1]format=gray[a];[0][a]alphamerge,format=yuva420p" \
  -c:v libvpx-vp9 out.webm
```

Read it back with `-c:v libvpx-vp9` before `-i`; FFmpeg's own VP9 decoder drops the alpha. ProRes 4444 (`-c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le out.mov`) also keeps it.

The graph outputs are in the order their labels first appear: `fill`, then `matte`. The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).
