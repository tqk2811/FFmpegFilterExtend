# Falling Maple Leaves

Red maple leaves falling over the video, spinning down on the wind.

## Inputs

- `src`

Any size; any pixel format that gpufx converts on the GPU.

## Output

Same size as the first input (`src`). Pixel format: the input's, when the effect may output it (the manifest has no `output` rule).

## Options

Written inline after the package name: `falling-maple.zip=name=value`. Several options are separated by `&` in an FFmpeg `effect='...'` string (`:` also works but must be written `\:` there) or by `:` in `gpufx run`. A value is a literal or an FFmpeg expression in `t`, `n`, `w`, `h`, `a`, `sar`, `dar`; commas inside an FFmpeg command line are escaped as `\,`. See the repo [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md) and [EFFECT_FORMAT](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/docs/EFFECT_FORMAT.md).

| Name | Type | Default | Range | Description |
|------|------|---------|-------|-------------|
| `mode` | int | `0` | 0 to 4 | Motion: 0 tumble (spin round, carried by the wind), 1 pendulum swing, 2 spiral, 3 no swing (wind still drifts), 4 custom path from path_x, path_y and angle |
| `count` | int | `50` | 0 to 256 | Number of leaf slots; strong wind carries part of them outside the frame |
| `seed` | int | `1` | 0 to 100000 | Changes which leaves fall where |
| `speed` | float | `0.18` | 0.01 to 5 | Fall speed, frame heights per second |
| `wind` | float | `0.12` | -2 to 2 | Sideways drift, frame heights per second (negative blows left) |
| `sway` | float | `0.04` | 0 to 1 | Side-to-side swing, in frame heights |
| `spin` | float | `2.5` | 0 to 20 | Rotation speed, radians per second |
| `size` | vec2 | `0.05, 0.11` | 0.005 to 1 | Smallest and largest leaf, in frame heights |
| `opacity` | float | `1` | 0 to 1 | Leaf opacity |
| `offset` | float | `0` | -100000 to 100000 | Seconds added to the time (e.g. to keep the leaves in place after -ss) |
| `life` | float | `6` | 0.1 to 600 | Mode 4: seconds a leaf lives before it respawns |
| `path_x` | expr | `x0 + 0.05*sin(tau*(0.5*u + r1))` | - | Mode 4: x of the leaf centre in frame heights (0 left, w right). t time, u seconds since the leaf appeared, p = u/life, i slot, r0..r3 random per leaf, x0 random in 0..w, w frame width and h frame height (1) in frame heights |
| `path_y` | expr | `-0.1 + 1.2*p` | - | Mode 4: y of the leaf centre in frame heights (0 top, 1 bottom); same variables as path_x |
| `angle` | expr | `r2*360 + 90*u` | - | Mode 4: rotation in degrees; same variables as path_x |

A `vec2` is two comma-separated numbers (`center=0.3,0.6`; write `0.3\,0.6` in an FFmpeg command line).

## Example

```sh
ffmpeg -init_hw_device vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk -i in.mp4 \
  -vf "format=nv12,gpufx=effect='falling-maple.zip=count=80&wind=0.2&seed=7',hwdownload,format=nv12" out.mp4
```

Direct3D 12 (Windows):

```sh
ffmpeg -init_hw_device d3d12va=dx -filter_hw_device dx -i in.mp4 \
  -vf "format=nv12,gpufx=effect='falling-maple.zip=count=80&wind=0.2&seed=7',hwdownload,format=nv12" out.mp4
```

The effect runs on every backend the filter supports (Vulkan, D3D12/D3D11, Metal on macOS); see the [README](https://github.com/tqk2811/FFmpegGpuFilter/blob/master/README.md).

## Notes

Package API 2. The leaf sprites are a 2x2 texture atlas shipped in the package (`textures/leaves.png`; licences in `assets/leaves/README.md`). Mode 4 evaluates `path_x`, `path_y` and `angle` on the GPU for every leaf.
