# Slideshow effects

Source: <https://github.com/tanersener/ffmpeg-video-slideshow-scripts>

The effects in this folder follow the scripts of
[tanersener/ffmpeg-video-slideshow-scripts](https://github.com/tanersener/ffmpeg-video-slideshow-scripts)
(MIT). Those scripts build a whole slideshow out of pictures with long FFmpeg filter graphs
(`overlay`, `zoompan`, `crop`, `geq`, `boxblur`...). Here each look is one GPU shader package driven by
`progress` (0 to 1), so it can be used between any two clips with `gpufx`.

No code was copied: the shaders are written anew from what the scripts show on screen. Timing and
easing can differ; the README of each effect lists what is different.

| Package | Scripts |
| --- | --- |
| [blinds](blinds/README.md) | `transition_scripts/bars_horizontal_one.sh`, `bars_horizontal_two.sh`, `bars_vertical_one.sh`, `bars_vertical_two.sh` |
| [box-in](box-in/README.md) | `transition_scripts/box_in_horizontal.sh`, `box_in_vertical.sh` |
| [checkerboard](checkerboard/README.md) | `transition_scripts/checkerboard.sh` |
| [collapse](collapse/README.md) | `transition_scripts/collapse_both.sh`, `collapse_circular.sh`, `collapse_horizontal.sh`, `collapse_vertical.sh` |
| [expand](expand/README.md) | `transition_scripts/expand_both.sh`, `expand_circular.sh`, `expand_horizontal.sh`, `expand_vertical.sh` |
| [fit](fit/README.md) | the `SCREEN_MODE` option shared by the scripts, and `advanced_scripts/blurred_background.sh` |
| [photo-collection](photo-collection/README.md) | `advanced_scripts/photo_collection.sh` |
| [push-box](push-box/README.md) | `transition_scripts/push_box_horizontal.sh`, `push_box_vertical.sh` |
| [push-film](push-film/README.md) | `advanced_scripts/push_horizontal_film.sh`, `push_vertical_film.sh` |
| [sliding-bars](sliding-bars/README.md) | `transition_scripts/sliding_bars_horizontal.sh`, `sliding_bars_vertical.sh` |
| [spin-transition](spin-transition/README.md) | `transition_scripts/spin_blur_rotation.sh` |

Some scripts are covered by the general effects in [../ffmpeg](../ffmpeg): `clock.sh` by
[clock-wipe](../ffmpeg/clock-wipe/README.md), `fade_in_*.sh` by [crossfade](../ffmpeg/crossfade/README.md) and
[dip-to-color](../ffmpeg/dip-to-color/README.md), `wipe_*.sh` by [wipe-transition](../ffmpeg/wipe-transition/README.md),
and `cover_*.sh` and `push_*.sh` by the modes of [slide-transition](../ffmpeg/slide-transition/README.md).
