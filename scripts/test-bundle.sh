#!/bin/sh
# Runs the gpufx effects through the ffmpeg of a bundle made by build-prebuilt.sh or
# build.sh, including the manifest rules (mismatches must fail).
#   scripts/test-bundle.sh dist/linux64 [clips-dir]
# Test clips come from another ffmpeg with lavfi sources ($REF_FFMPEG, default `ffmpeg`),
# since the bundle has no video source filters; pass clips-dir to reuse existing ones.
# Clips and logs default to build/test-<bundle name>, outside the bundle.
# TEST_CLIPS_ONLY=1 only writes the clips (for a runner that has no reference ffmpeg).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST=$(cd "${1:?usage: test-bundle.sh <bundle dir> [clips dir]}" && pwd)
CLIPS=${2:-$ROOT/build/test-$(basename "$DIST")}
mkdir -p "$CLIPS"
CLIPS=$(cd "$CLIPS" && pwd)
FF=$DIST/bin/ffmpeg
[ -f "$FF" ] || FF=$DIST/bin/ffmpeg.exe
# Effects are passed relative to the bundle: a Windows path (C:/...) would break the
# filter graph, where ':' separates options.
FX=effects

if [ ! -f "$CLIPS/straight.png" ]; then
    REF=${REF_FFMPEG:-ffmpeg}
    "$REF" -v error -y -f lavfi -i testsrc2=s=320x180:d=1 -f lavfi -i sine=d=1 \
        -c:v ffv1 -c:a flac -shortest "$CLIPS/a.mkv"
    "$REF" -v error -y -f lavfi -i smptebars=s=320x180:d=1 -c:v ffv1 "$CLIPS/b.mkv"
    "$REF" -v error -y -f lavfi -i smptebars=s=300x180:d=1 -c:v ffv1 "$CLIPS/c.mkv"
    # Same size as a.mkv (25 fps) but 60 fps, for the frame rate test. NUT stores a 1/60
    # time base, so the output time base differs from a.mkv's 1/1000 (duration test).
    "$REF" -v error -y -f lavfi -i smptebars=s=320x180:r=60:d=1 -c:v ffv1 "$CLIPS/d.nut"
    # BT.709 limited range YUV (colorspace test) with non-square pixels (SAR warning).
    "$REF" -v error -y -f lavfi -i testsrc2=s=320x180:d=1 -vf setsar=2 -pix_fmt yuv420p \
        -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
        -c:v ffv1 "$CLIPS/e.mkv"
    # Size changes from 320x180 to 300x180 in the middle of one stream. MJPEG carries the
    # size in every frame (FFV1 would decode the second clip at the first size).
    "$REF" -v error -y -f lavfi -i testsrc2=s=320x180:d=0.4 -pix_fmt yuvj420p -c:v mjpeg "$CLIPS/r1.mkv"
    "$REF" -v error -y -f lavfi -i testsrc2=s=300x180:d=0.4 -pix_fmt yuvj420p -c:v mjpeg "$CLIPS/r2.mkv"
    # Half transparent image; FFmpeg 9 decodes EXR alpha as premultiplied.
    "$REF" -v error -y -f lavfi -i testsrc2=s=64x36 -vf format=rgba,colorchannelmixer=aa=0.5 \
        -frames:v 1 -c:v exr "$CLIPS/premul.exr"
    # Same size, straight alpha (the PNG decoder says so).
    "$REF" -v error -y -f lavfi -i testsrc2=s=64x36 -vf format=rgba -frames:v 1 "$CLIPS/straight.png"
    printf "file 'r1.mkv'\nfile 'r2.mkv'\n" > "$CLIPS/resize.txt"
fi
[ "${TEST_CLIPS_ONLY:-0}" = 1 ] && exit 0
A=$CLIPS/a.mkv B=$CLIPS/b.mkv C=$CLIPS/c.mkv D=$CLIPS/d.nut E=$CLIPS/e.mkv R=$CLIPS/resize.txt
X=$CLIPS/premul.exr P=$CLIPS/straight.png
if command -v cygpath >/dev/null; then   # Git Bash on Windows: give ffmpeg.exe C:/ paths
    A=$(cygpath -m "$A") B=$(cygpath -m "$B") C=$(cygpath -m "$C") D=$(cygpath -m "$D")
    E=$(cygpath -m "$E") R=$(cygpath -m "$R") X=$(cygpath -m "$X") P=$(cygpath -m "$P")
fi
cd "$DIST"

fails=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
# ok NAME ARGS...: must succeed
ok() {
    name=$1; shift
    if "$FF" -hide_banner -nostdin -v error "$@" > "$CLIPS/last.log" 2>&1; then pass "$name"
    else fail "$name"; cat "$CLIPS/last.log"; fi
}
# warns NAME PATTERN ARGS...: must succeed with the warning PATTERN in the log
warns() {
    name=$1 pattern=$2; shift 2
    if ! "$FF" -hide_banner -nostdin -v warning "$@" > "$CLIPS/last.log" 2>&1; then fail "$name (failed)"; cat "$CLIPS/last.log"
    elif grep -q "$pattern" "$CLIPS/last.log"; then pass "$name"
    else fail "$name (no warning)"; cat "$CLIPS/last.log"; fi
}
# rejects NAME PATTERN ARGS...: must fail with PATTERN in the log
rejects() {
    name=$1 pattern=$2; shift 2
    if "$FF" -hide_banner -nostdin -v error "$@" > "$CLIPS/last.log" 2>&1; then fail "$name (was accepted)"
    elif grep -q "$pattern" "$CLIPS/last.log"; then pass "$name"
    else fail "$name (wrong error)"; cat "$CLIPS/last.log"; fi
}

"$FF" -hide_banner -version | head -n1
"$FF" -hide_banner -filters > "$CLIPS/filters.txt" 2>&1
grep -qw gpufx "$CLIPS/filters.txt" && pass "gpufx is registered" || fail "gpufx is registered"
if grep -qwE "overlay|drawtext|gblur" "$CLIPS/filters.txt"; then fail "built-in video filters removed"; else pass "built-in video filters removed"; fi

NULL="-f null -"
# Two input transitions driven by `progress`.
TRANSITIONS="wipe-transition crossfade slide-transition circle-reveal clock-wipe collapse expand dip-to-color dissolve pixelize-transition zoom-transition fade-grays blinds"
echo "single input effects (audio stream kept):"
for e in "$FX"/*.zip; do
    case " $TRANSITIONS overlay " in *" $(basename "$e" .zip) "*) continue ;; esac
    # shellcheck disable=SC2086
    ok "$(basename "$e" .zip)" -i "$A" -vf "gpufx=effect=$e" $NULL
done
echo "two input effects:"
for e in $TRANSITIONS; do
    # shellcheck disable=SC2086
    ok "$e" -i "$A" -i "$B" -filter_complex "[0][1]gpufx=effect=$FX/$e.zip:params='progress=t'" -an $NULL
done
# shellcheck disable=SC2086
ok "overlay (different sizes)" -i "$A" -i "$C" -filter_complex "[0][1]gpufx=effect=$FX/overlay.zip:params='border=2'" -an $NULL
echo "expressions, sendcmd, timeline, chains:"
# shellcheck disable=SC2086
ok "expression params" -i "$A" -vf "gpufx=effect=$FX/vignette.zip:params='strength=clip(t\,0\,1)|color=#ff0000'" $NULL
# shellcheck disable=SC2086
ok "expression params: a, sar, dar" -i "$E" -vf "gpufx=effect=$FX/vignette.zip:params='strength=clip(dar/a/sar-0.5\,0\,1)'" $NULL
# shellcheck disable=SC2086
ok "sendcmd + chain" -i "$A" -vf "gpufx=effect=$FX/gaussian-blur.zip,sendcmd=c='0.5 gpufx@g params intensity=0.2',gpufx@g=effect=$FX/gradient-map.zip,gpufx=effect=$FX/rgb-split.zip" $NULL
# shellcheck disable=SC2086
ok "timeline enable" -i "$A" -vf "format=yuv420p,gpufx=effect=$FX/chroma-key.zip:enable='gte(t\,0.5)',format=yuva420p" $NULL
# shellcheck disable=SC2086
ok "encode mpeg4 + aac" -i "$A" -vf "gpufx=effect=$FX/sepia.zip" -c:v mpeg4 -c:a aac -y "$CLIPS/out.mp4"
echo "manifest rules:"
# shellcheck disable=SC2086
ok "chroma-key: yuv420p in, yuva420p out" -i "$A" -vf "format=yuv420p,gpufx=effect=$FX/chroma-key.zip,format=yuva420p" $NULL
# shellcheck disable=SC2086
rejects "chroma-key: gray input" "pixel format .gray. is not supported" -i "$A" -vf "format=gray,gpufx=effect=$FX/chroma-key.zip" $NULL
# shellcheck disable=SC2086
rejects "crossfade: inputs of different sizes" "must equal the first input" -i "$A" -i "$C" -filter_complex "[0][1]gpufx=effect=$FX/crossfade.zip" -an $NULL
# Without graph reinit, frames of the new size reach gpufx: it must refuse them, not
# overflow its buffers. chroma-key takes YUV as it is, so no scale sits in between.
# shellcheck disable=SC2086
rejects "size change mid-stream" "changed from 320x180 yuvj420p to 300x180" -reinit_filter 0 -f concat -i "$R" -an -vf "gpufx=effect=$FX/chroma-key.zip" $NULL
echo "warnings:"
# shellcheck disable=SC2086
warns "different sample aspect ratios" "has sample aspect ratio 2:1" -i "$A" -i "$E" -filter_complex "[0][1]gpufx=effect=$FX/crossfade.zip" -an $NULL

echo "pixels:"
# The GPU must really change frames: invert once differs from the source, twice restores
# it exactly (8-bit, 1 - (1 - x) has no rounding loss).
md5() {
    "$FF" -hide_banner -nostdin -v error -i "$A" -frames:v 3 -an -vf "$1" -pix_fmt rgba -f framemd5 - \
        2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}'
}
SRC_MD5=$(md5 "format=rgba")
ONCE_MD5=$(md5 "gpufx=effect=$FX/invert.zip")
TWICE_MD5=$(md5 "gpufx=effect=$FX/invert.zip,gpufx=effect=$FX/invert.zip")
if [ -n "$SRC_MD5" ] && [ "$ONCE_MD5" != "$SRC_MD5" ] && [ "$TWICE_MD5" = "$SRC_MD5" ]; then
    pass "invert changes pixels, twice restores them"
else
    fail "invert changes pixels, twice restores them"; cat "$CLIPS/last.log"
fi
# Both filters share one compiled package; their parameters must stay separate.
SHARED_MD5=$(md5 "gpufx=effect=$FX/invert.zip,gpufx=effect=$FX/invert.zip:params='amount=0'")
if [ -n "$ONCE_MD5" ] && [ "$SHARED_MD5" = "$ONCE_MD5" ]; then
    pass "same package twice keeps parameters per filter"
else
    fail "same package twice keeps parameters per filter"; cat "$CLIPS/last.log"
fi

echo "frame rate:"
# The first input sets the output frame rate: a 25 fps clip mixed with a 60 fps clip must
# give exactly the 25 fps timestamps and durations (passthrough keeps what the filter
# emits), although the inputs have different time bases.
pts() {
    "$FF" -hide_banner -nostdin -v error "$@" -an -fps_mode passthrough -enc_time_base filter \
        -f framemd5 - 2> "$CLIPS/last.log" |
        # pts and duration in milliseconds: the time bases of the two runs differ.
        awk -F'[ ,:/]+' '/^#tb 0/ {num = $3; den = $4; next} /^#/ {next}
                        {printf "%d/%d ", $3 * num * 1000 / den + 0.5, $4 * num * 1000 / den + 0.5}'
}
MAIN_PTS=$(pts -i "$A" -vf "format=rgba")
MIXED_PTS=$(pts -i "$A" -i "$D" -filter_complex "[0][1]gpufx=effect=$FX/crossfade.zip")
if [ -n "$MAIN_PTS" ] && [ "$MIXED_PTS" = "$MAIN_PTS" ]; then
    pass "25 fps + 60 fps input keeps the 25 fps timestamps and durations"
else
    fail "25 fps + 60 fps input keeps the 25 fps timestamps and durations"
    echo "    want: $MAIN_PTS"; echo "    got:  $MIXED_PTS"; cat "$CLIPS/last.log"
fi

echo "colors:"
# RGBA -> YUV inside gpufx must use the output link colorspace and range (BT.709 here),
# exactly like an auto-inserted scale after an RGBA output does.
yuv_md5() {
    "$FF" -hide_banner -nostdin -v error -i "$E" -frames:v 3 -an -vf "$1" -pix_fmt yuva420p \
        -colorspace bt709 -color_range tv -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}'
}
VIA_SCALE=$(yuv_md5 "gpufx=effect=$FX/chroma-key.zip,format=rgba,format=yuva420p")
INSIDE=$(yuv_md5 "gpufx=effect=$FX/chroma-key.zip,format=yuva420p")
if [ -n "$VIA_SCALE" ] && [ "$INSIDE" = "$VIA_SCALE" ]; then
    pass "YUV output follows the BT.709 output link"
else
    fail "YUV output follows the BT.709 output link"; cat "$CLIPS/last.log"
fi

echo "premultiplied alpha:"
# The bundles have no premultiply_dynamic filter: gpufx converts alpha modes itself.
# shellcheck disable=SC2086
ok "premultiplied input (EXR)" -i "$X" -vf "gpufx=effect=$FX/invert.zip" $NULL
# shellcheck disable=SC2086
ok "premultiplied and straight inputs together" -i "$X" -i "$P" -filter_complex "[0][1]gpufx=effect=$FX/crossfade.zip" $NULL
ok "premultiplied output (EXR)" -i "$X" -vf "format=rgba,gpufx=effect=$FX/chroma-key.zip" -c:v exr -f image2 -update 1 -y "$CLIPS/out.exr"

echo "late second input:"
# Main frames before the second input starts are kept, with a transparent second input.
count() {
    "$FF" -hide_banner -nostdin -v error "$@" -an -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | wc -l | tr -d ' '
}
MAIN_N=$(count -i "$A" -vf "format=rgba")
LATE_N=$(count -i "$A" -itsoffset 0.5 -i "$B" -filter_complex "[0][1]gpufx=effect=$FX/crossfade.zip:params='progress=0.5'")
if [ "$MAIN_N" -gt 0 ] && [ "$LATE_N" = "$MAIN_N" ]; then
    pass "second input starting at 0.5 s keeps all $MAIN_N main frames"
else
    fail "second input starting at 0.5 s keeps all main frames (want $MAIN_N, got $LATE_N)"; cat "$CLIPS/last.log"
fi

echo "falling leaves:"
# Leaves are a function of the frame time only: seeking must draw the same last frame.
last_md5() {
    "$FF" -hide_banner -nostdin -v error "$@" -an -vf "gpufx=effect=$FX/falling-maple.zip" -pix_fmt rgba \
        -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | tail -n 1 | awk -F, '{print $NF}'
}
FULL_MD5=$(last_md5 -i "$A")
SEEK_MD5=$(last_md5 -ss 0.6 -copyts -i "$A")
if [ -n "$FULL_MD5" ] && [ "$FULL_MD5" = "$SEEK_MD5" ]; then
    pass "falling-maple: seeking draws the same frame"
else
    fail "falling-maple: seeking draws the same frame"; cat "$CLIPS/last.log"
fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
