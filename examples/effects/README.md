# Example effects

Each folder is one effect package (see [EFFECT_FORMAT](../../docs/EFFECT_FORMAT.md)), grouped by origin. `scripts/pack-effects.sh` zips every one to `dist/effects/<group>/<name>.zip`, keeping this layout; the release bundles ship the same `effects/<group>/` folders.

## ffmpeg

Equivalents of FFmpeg built-in filters and `xfade` transitions.

- [fade](ffmpeg/fade/README.md)
- [crossfade](ffmpeg/crossfade/README.md)
- [dissolve](ffmpeg/dissolve/README.md)
- [dip-to-color](ffmpeg/dip-to-color/README.md)
- [fade-grays](ffmpeg/fade-grays/README.md)
- [pixelize-transition](ffmpeg/pixelize-transition/README.md)
- [zoom-transition](ffmpeg/zoom-transition/README.md)
- [wipe-transition](ffmpeg/wipe-transition/README.md)
- [slide-transition](ffmpeg/slide-transition/README.md)
- [circle-reveal](ffmpeg/circle-reveal/README.md)
- [clock-wipe](ffmpeg/clock-wipe/README.md)
- [grayscale](ffmpeg/grayscale/README.md)
- [sepia](ffmpeg/sepia/README.md)
- [invert](ffmpeg/invert/README.md)
- [vignette](ffmpeg/vignette/README.md)
- [edge-detect](ffmpeg/edge-detect/README.md)
- [gaussian-blur](ffmpeg/gaussian-blur/README.md)
- [sharpen](ffmpeg/sharpen/README.md)
- [pixelate](ffmpeg/pixelate/README.md)
- [chroma-key](ffmpeg/chroma-key/README.md)
- [color-adjust](ffmpeg/color-adjust/README.md)
- [mirror](ffmpeg/mirror/README.md)
- [transform](ffmpeg/transform/README.md)
- [overlay](ffmpeg/overlay/README.md)

## slideshow

Transitions and helpers ported from [tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts).

- [blinds](slideshow/blinds/README.md)
- [box-in](slideshow/box-in/README.md)
- [checkerboard](slideshow/checkerboard/README.md)
- [collapse](slideshow/collapse/README.md)
- [expand](slideshow/expand/README.md)
- [push-box](slideshow/push-box/README.md)
- [push-film](slideshow/push-film/README.md)
- [photo-collection](slideshow/photo-collection/README.md)
- [fit](slideshow/fit/README.md)
- [sliding-bars](slideshow/sliding-bars/README.md)
- [spin-transition](slideshow/spin-transition/README.md)

## standalone

Effects of our own, with no FFmpeg or script counterpart.

- [falling-ginkgo](standalone/falling-ginkgo/README.md)
- [falling-maple](standalone/falling-maple/README.md)
- [gradient-map](standalone/gradient-map/README.md)
- [rgb-split](standalone/rgb-split/README.md)

## capcut

Recreations of CapCut transitions, written from scratch in WGSL (no CapCut assets). `scripts/capcut-compare.py` scores one against a demo exported from CapCut (per-frame PSNR/SSIM and a side-by-side sheet).

- [pull-out](capcut/pull-out/README.md)
- [black-fade](capcut/black-fade/README.md)
- [mix](capcut/mix/README.md)
- [wipe-right](capcut/wipe-right/README.md)
- [slide-right](capcut/slide-right/README.md)
- [open](capcut/open/README.md)
- [split-2](capcut/split-2/README.md)
- [horizontal-blur](capcut/horizontal-blur/README.md)
- [flip-page](capcut/flip-page/README.md)
- [turn-table](capcut/turn-table/README.md)
- [shaky-inhale](capcut/shaky-inhale/README.md)
- [elastic-glowing](capcut/elastic-glowing/README.md)
- [fan-out](capcut/fan-out/README.md)
- [dial-turn](capcut/dial-turn/README.md)
- [hot-shimmers](capcut/hot-shimmers/README.md)
- [fold-over](capcut/fold-over/README.md)
- [dramatic-vortex](capcut/dramatic-vortex/README.md)
- [slide-film](capcut/slide-film/README.md)
- [big-wave](capcut/big-wave/README.md)
- [fisheye-wipe](capcut/fisheye-wipe/README.md)
- [whip-tear](capcut/whip-tear/README.md)
- [wide-ripple](capcut/wide-ripple/README.md)
- [thermal-imaging-3](capcut/thermal-imaging-3/README.md)
- [dazzle-pulse](capcut/dazzle-pulse/README.md)
- [centerfold-wipe](capcut/centerfold-wipe/README.md)
- [wipers](capcut/wipers/README.md)
- [fade-up](capcut/fade-up/README.md)
- [slice-reveal](capcut/slice-reveal/README.md)
- [twinkle-zoom](capcut/twinkle-zoom/README.md)
- [ripple-vibe](capcut/ripple-vibe/README.md)
- [fisheye-zoom](capcut/fisheye-zoom/README.md)
- [break-swipe](capcut/break-swipe/README.md)
