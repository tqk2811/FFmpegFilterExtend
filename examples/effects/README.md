# Example effects

Each folder is one effect package (see [EFFECT_FORMAT](../../docs/EFFECT_FORMAT.md)), grouped by origin. A package is referred to by its folder name, wherever the group folder is: `scripts/pack-effects.sh` zips every one to `dist/effects/<name>.zip`.

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
