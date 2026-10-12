#!/bin/sh
# Runs the gpufx effects through the ffmpeg of a bundle made by build-prebuilt.sh or
# build.sh, including the manifest rules (mismatches must fail).
#   scripts/test-bundle.sh dist/linux64 [clips-dir]
# Test clips come from another ffmpeg with lavfi sources ($REF_FFMPEG, default `ffmpeg`),
# since the bundle has no video source filters; pass clips-dir to reuse existing ones.
# Clips and logs default to build/test-<bundle name>, outside the bundle.
# TEST_CLIPS_ONLY=1 only writes the clips (for a runner that has no reference ffmpeg).
# REQUIRE_D3D=1 fails when the D3D12 or D3D11 frame tests are skipped.
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
TRANSITIONS="wipe-transition crossfade slide-transition circle-reveal clock-wipe collapse expand dip-to-color dissolve pixelize-transition zoom-transition fade-grays blinds checkerboard push-box push-film photo-collection"
echo "single input effects (audio stream kept):"
for e in "$FX"/*.zip; do
    case " $TRANSITIONS overlay fit " in *" $(basename "$e" .zip) "*) continue ;; esac
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
for m in 0 1 2 3; do
    # shellcheck disable=SC2086
    ok "fit mode $m (different sizes)" -i "$A" -i "$C" -filter_complex "[0][1]gpufx=effect=$FX/fit.zip:params='mode=$m'" -an $NULL
done
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
# it exactly (8-bit RGBA, 1 - (1 - x) has no rounding loss). The frames are RGBA before
# gpufx, else it converts YUV itself and differs from swscale by rounding.
md5() {
    "$FF" -hide_banner -nostdin -v error -i "$A" -frames:v 3 -an -vf "format=rgba,$1" -pix_fmt rgba -f framemd5 - \
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
echo "chains in one filter:"
# effect='a|b' runs both on the GPU in one go: same pixels as two filters in a row.
CHAIN_MD5=$(md5 "gpufx=effect='$FX/invert.zip|$FX/invert.zip'")
if [ -n "$SRC_MD5" ] && [ "$CHAIN_MD5" = "$SRC_MD5" ]; then pass "invert|invert restores the frame"
else fail "invert|invert restores the frame"; cat "$CLIPS/last.log"; fi
TWO_MD5=$(md5 "gpufx=effect=$FX/grayscale.zip,gpufx=effect=$FX/vignette.zip:params='strength=0.8'")
ONE_MD5=$(md5 "gpufx=effect='$FX/grayscale.zip|$FX/vignette.zip':params='vignette.strength=0.8'")
if [ -n "$TWO_MD5" ] && [ "$ONE_MD5" = "$TWO_MD5" ]; then pass "grayscale|vignette equals two filters"
else fail "grayscale|vignette equals two filters"; cat "$CLIPS/last.log"; fi
# Parameters by index (spaces around | allowed), and expressions on qualified names.
IDX_MD5=$(md5 "gpufx=effect='$FX/invert.zip | $FX/invert.zip':params='1.amount=0'")
EXPR_MD5=$(md5 "gpufx=effect='$FX/invert.zip|$FX/invert.zip':params='1.amount=0*t'")
if [ -n "$ONCE_MD5" ] && [ "$IDX_MD5" = "$ONCE_MD5" ] && [ "$EXPR_MD5" = "$ONCE_MD5" ]; then pass "index.param and expressions"
else fail "index.param and expressions"; cat "$CLIPS/last.log"; fi
# shellcheck disable=SC2086
rejects "ambiguous parameter" "0.amount, 1.amount" -i "$A" -an -vf "gpufx=effect='$FX/invert.zip|$FX/invert.zip':params='amount=0'" $NULL
# shellcheck disable=SC2086
rejects "only the first effect takes two inputs" "takes 2 inputs" -i "$A" -an -vf "gpufx=effect='$FX/invert.zip|$FX/crossfade.zip'" $NULL
# shellcheck disable=SC2086
ok "a transition first in a chain" -i "$A" -i "$B" -filter_complex "[0][1]gpufx=effect='$FX/crossfade.zip|$FX/invert.zip'" -an $NULL

echo "graphs in one filter:"
# graph='...' runs a DAG on the GPU: same pixels as the filters it stands for.
SPLIT_MD5=$(md5 "split[a][b];[a]gpufx=effect=$FX/grayscale.zip[g];[g][b]gpufx=effect=$FX/crossfade.zip:params='progress=0.3'")
GRAPH_MD5=$(md5 "gpufx=graph='[0]split[a][b]; [a]$FX/grayscale.zip[g]; [g][b]$FX/crossfade.zip[out]':params='progress=0.3'")
if [ -n "$SPLIT_MD5" ] && [ "$GRAPH_MD5" = "$SPLIT_MD5" ]; then pass "graph with split equals split + two filters"
else fail "graph with split equals split + two filters"; cat "$CLIPS/last.log"; fi
LINEAR_MD5=$(md5 "gpufx=graph='[0]$FX/invert.zip|$FX/invert.zip[out]'")
if [ -n "$SRC_MD5" ] && [ "$LINEAR_MD5" = "$SRC_MD5" ]; then pass "linear graph invert|invert restores the frame"
else fail "linear graph invert|invert restores the frame"; cat "$CLIPS/last.log"; fi
# Two output pads mapped to two files, emitted together: each equals its effect alone.
rm -f "$CLIPS/p.md5" "$CLIPS/q.md5"
"$FF" -hide_banner -nostdin -v error -i "$A" -filter_complex \
    "[0:v]format=rgba,gpufx=graph='[0]split[a][b]; [a]$FX/invert.zip[inv]; [b]$FX/grayscale.zip[gray]'[p][q]" \
    -map "[p]" -frames:v 3 -pix_fmt rgba -f framemd5 -y "$CLIPS/p.md5" \
    -map "[q]" -frames:v 3 -pix_fmt rgba -f framemd5 -y "$CLIPS/q.md5" > "$CLIPS/last.log" 2>&1
P_MD5=$(grep -v '^#' "$CLIPS/p.md5" 2>/dev/null | awk -F, '{print $NF}')
Q_MD5=$(grep -v '^#' "$CLIPS/q.md5" 2>/dev/null | awk -F, '{print $NF}')
GRAY_MD5=$(md5 "gpufx=effect=$FX/grayscale.zip")
if [ -n "$P_MD5" ] && [ "$P_MD5" = "$ONCE_MD5" ] && [ "$Q_MD5" = "$GRAY_MD5" ]; then pass "two output pads to two files"
else fail "two output pads to two files"; cat "$CLIPS/last.log"; fi
# Two inputs, two outputs, parameters by node label, sendcmd and the timeline.
# shellcheck disable=SC2086
ok "graph: 2 inputs, 2 outputs, sendcmd, enable" -i "$A" -i "$B" -filter_complex \
    "[0:v][1:v]gpufx@g=graph='[0]split[a][b]; [a]$FX/gaussian-blur.zip[ba]; [b]$FX/grayscale.zip|$FX/vignette.zip[gb]; [ba][gb]$FX/crossfade.zip[x]; [x]split[x1][x2]; [x2][1]$FX/wipe-transition.zip[out]':params='x.progress=0.5|out.progress=t':enable='lt(t\,0.8)'[p][q];[q]sendcmd=c='0.5 gpufx@g params gb.strength=0.2',nullsink" \
    -map "[p]" -an $NULL
# shellcheck disable=SC2086
rejects "graph: effect and graph together" "not both" -i "$A" -an -vf "gpufx=effect=$FX/invert.zip:graph='[0]$FX/invert.zip[o]'" $NULL
# shellcheck disable=SC2086
rejects "graph: cycle" "cycle through" -i "$A" -an -vf "gpufx=graph='[0][b]$FX/crossfade.zip[a]; [a]split[b][out]'" $NULL
# shellcheck disable=SC2086
rejects "graph: label never written" "is read but never written" -i "$A" -an -vf "gpufx=graph='[0][c]$FX/crossfade.zip[out]'" $NULL
# shellcheck disable=SC2086
rejects "graph: label read twice" "is read twice" -i "$A" -an -vf "gpufx=graph='[0]$FX/invert.zip[a]; [a][a]$FX/crossfade.zip[out]'" $NULL
# shellcheck disable=SC2086
rejects "graph: wrong number of labels" "takes 2 inputs, the node gives it 1" -i "$A" -an -vf "gpufx=graph='[0]$FX/crossfade.zip[out]'" $NULL
# shellcheck disable=SC2086
rejects "graph: same size rule inside the graph" "must equal the first input" -i "$A" -i "$C" -filter_complex "[0][1]gpufx=graph='[0]$FX/invert.zip[i]; [i][1]$FX/crossfade.zip[out]'" -an $NULL

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
# raw OUT ARGS...: first 3 frames as raw video.
raw() {
    out=$1; shift
    "$FF" -hide_banner -nostdin -v error "$@" -frames:v 3 -an -f rawvideo -y "$out" 2> "$CLIPS/last.log"
}
# diff_stats A B BYTES: "max mean" of the differences of the 1 or 2 byte samples.
diff_stats() {
    od -An -v -tu"$3" "$1" | tr -s ' ' '\n' | grep -v '^$' > "$CLIPS/a.txt"
    od -An -v -tu"$3" "$2" | tr -s ' ' '\n' | grep -v '^$' > "$CLIPS/b.txt"
    paste "$CLIPS/a.txt" "$CLIPS/b.txt" | awk '{d = $1 - $2; if (d < 0) d = -d; if (d > m) m = d; s += d; n++}
                                              END {if (n) printf "%d %.3f\n", m, s / n}'
}
# below VALUE LIMIT: VALUE < LIMIT
below() { awk -v v="$1" -v l="$2" 'BEGIN {exit !(v < l)}'; }
# RGBA -> YUV inside gpufx (on the GPU now) must use the output link colorspace and range
# (BT.709 here), like an auto-inserted scale after an RGBA output: the same picture up
# to rounding and chroma filtering, far from what a BT.601 output gives.
raw "$CLIPS/scale.yuv" -i "$E" -vf "gpufx=effect=$FX/chroma-key.zip,format=rgba,format=yuva420p" -pix_fmt yuva420p -colorspace bt709 -color_range tv
raw "$CLIPS/inside.yuv" -i "$E" -vf "gpufx=effect=$FX/chroma-key.zip,format=yuva420p" -pix_fmt yuva420p -colorspace bt709 -color_range tv
raw "$CLIPS/bt601.yuv" -i "$E" -vf "gpufx=effect=$FX/chroma-key.zip,format=yuva420p" -pix_fmt yuva420p -colorspace bt470bg -color_range tv
GOOD=$(diff_stats "$CLIPS/scale.yuv" "$CLIPS/inside.yuv" 1 | cut -d' ' -f2)
BAD=$(diff_stats "$CLIPS/scale.yuv" "$CLIPS/bt601.yuv" 1 | cut -d' ' -f2)
if [ -n "$GOOD" ] && [ -n "$BAD" ] && below "$GOOD" 1 && below 3 "$BAD"; then
    pass "YUV output follows the BT.709 output link (mean difference $GOOD, BT.601 $BAD)"
else
    fail "YUV output follows the BT.709 output link (mean difference $GOOD, BT.601 $BAD)"; cat "$CLIPS/last.log"
fi
# yuv420p in and out: gpufx converts on the GPU, FFmpeg inserts no scale filter.
"$FF" -hide_banner -nostdin -v verbose -i "$A" -frames:v 2 -an -vf "gpufx=effect=$FX/invert.zip" -pix_fmt yuv420p -f null - > "$CLIPS/last.log" 2>&1
if grep -q "Loaded 'Invert'" "$CLIPS/last.log" && ! grep -q auto_scale "$CLIPS/last.log"; then pass "yuv420p in and out without swscale"
else fail "yuv420p in and out without swscale"; cat "$CLIPS/last.log"; fi
# GPU formats round trip: invert twice gives the frame back, up to chroma filtering on
# the sharp edges of testsrc2 (limits in sample units: 8-bit, P010 high bits, 10-bit).
for spec in nv12:1:2 yuv420p:1:2 p010le:2:640 yuv420p10le:2:10; do
    f=${spec%%:*} rest=${spec#*:}; bytes=${rest%%:*} limit=${rest#*:}
    raw "$CLIPS/ref.yuv" -i "$A" -vf "format=$f" -pix_fmt "$f"
    raw "$CLIPS/gpu.yuv" -i "$A" -vf "format=$f,gpufx=effect=$FX/invert.zip,gpufx=effect=$FX/invert.zip" -pix_fmt "$f"
    MEAN=$(diff_stats "$CLIPS/ref.yuv" "$CLIPS/gpu.yuv" "$bytes" | cut -d' ' -f2)
    if [ -n "$MEAN" ] && below "$MEAN" "$limit"; then pass "$f through the GPU (mean difference $MEAN)"
    else fail "$f through the GPU (mean difference $MEAN)"; cat "$CLIPS/last.log"; fi
done

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

echo "Vulkan frames:"
# hwupload -> gpufx -> hwdownload runs on FFmpeg's own Vulkan device, frames never leave
# the GPU in between, and must give exactly the pixels of the software path. One image per
# plane (disable_multiplane=1) is what gpufx reads and writes.
VKDEV="vulkan=vk:0,disable_multiplane=1"
vk_ff() { "$FF" -hide_banner -nostdin -v error -init_hw_device "$VKDEV" -filter_hw_device vk "$@"; }
# vk_md5 FORMAT FILTERS...: framemd5 of 3 frames of A in FORMAT, uploaded first.
vk_md5() {
    f=$1; shift
    vk_ff -i "$A" -frames:v 3 -an -vf "format=$f,hwupload,$1,hwdownload,format=$f" -pix_fmt "$f" -f framemd5 - \
        2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}'
}
sw_md5() {
    "$FF" -hide_banner -nostdin -v error -i "$A" -frames:v 3 -an -vf "format=$1,$2" -pix_fmt "$1" -f framemd5 - \
        2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}'
}
# same NAME HW_MD5 SW_MD5
same() {
    if [ -n "$2" ] && [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; cat "$CLIPS/last.log"; fi
}
if ! grep -qw hwupload "$CLIPS/filters.txt"; then
    echo "  skip  this bundle has no hwupload"
elif ! vk_ff -i "$A" -frames:v 1 -an -vf "format=rgba,hwupload,hwdownload,format=rgba" -f null - > "$CLIPS/last.log" 2>&1; then
    echo "  skip  no Vulkan device ($(head -n1 "$CLIPS/last.log"))"
elif ! vk_ff -i "$A" -frames:v 1 -an -vf "format=rgba,hwupload,gpufx=effect=$FX/invert.zip,hwdownload,format=rgba" -f null - > "$CLIPS/last.log" 2>&1; then
    # A gpufx without Vulkan frames does not take AV_PIX_FMT_VULKAN: no format in common.
    if grep -q "Impossible to convert\|No format\|negotiat" "$CLIPS/last.log"; then echo "  skip  this gpufx is built without Vulkan frames"
    else fail "gpufx takes Vulkan frames"; cat "$CLIPS/last.log"; fi
else
    same "rgba: grayscale on Vulkan frames equals the software path" \
        "$(vk_md5 rgba "gpufx=effect=$FX/grayscale.zip")" "$(sw_md5 rgba "gpufx=effect=$FX/grayscale.zip")"
    for f in nv12 yuv420p yuv444p p010le yuv420p10le rgba64le; do
        same "$f: vignette on Vulkan frames equals the software path" \
            "$(vk_md5 $f "gpufx=effect=$FX/vignette.zip:params='strength=0.7'")" \
            "$(sw_md5 $f "gpufx=effect=$FX/vignette.zip:params='strength=0.7'")"
    done
    # Two gpufx in a row: the second waits on the semaphores the first signals.
    same "invert twice on Vulkan frames restores the frame" \
        "$(vk_md5 rgba "gpufx=effect=$FX/invert.zip,gpufx=effect=$FX/invert.zip")" "$(sw_md5 rgba "null")"
    # A graph whose two inputs are one frame (split before gpufx): locked and waited once.
    G="[0]split[a][b]; [a]$FX/gaussian-blur.zip[ba]; [b]$FX/grayscale.zip|$FX/vignette.zip[gb]; [ba][gb]$FX/crossfade.zip[x]; [x][1]$FX/wipe-transition.zip[out]"
    same "graph on Vulkan frames equals the software path" \
        "$(vk_md5 nv12 "split[p][q];[p][q]gpufx=graph='$G':params='x.progress=0.4|out.progress=0.6'")" \
        "$(sw_md5 nv12 "split[p][q];[p][q]gpufx=graph='$G':params='x.progress=0.4|out.progress=0.6'")"
    # Output in another format than the input (the effect may output yuv420p or rgba).
    VK_OUT=$(vk_ff -i "$A" -frames:v 3 -an -vf "format=nv12,hwupload,gpufx=effect=$FX/sepia.zip,hwdownload,format=nv12" \
        -pix_fmt nv12 -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')
    same "sepia keeps nv12 on Vulkan frames" "$VK_OUT" "$(sw_md5 nv12 "gpufx=effect=$FX/sepia.zip,format=nv12")"
    # shellcheck disable=SC2086
    ok "timeline enable on Vulkan frames" -init_hw_device "$VKDEV" -filter_hw_device vk -i "$A" -an \
        -vf "format=nv12,hwupload,gpufx=effect=$FX/invert.zip:enable='gte(t\,0.5)',hwdownload,format=nv12" $NULL
    LATE_VK=$(vk_ff -i "$A" -itsoffset 0.5 -i "$B" -an -filter_complex \
        "[0]format=rgba,hwupload[a];[1]format=rgba,hwupload[b];[a][b]gpufx=effect=$FX/crossfade.zip:params='progress=0.5',hwdownload,format=rgba" \
        -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | wc -l | tr -d ' ')
    if [ "$LATE_VK" = "$MAIN_N" ]; then pass "late second input on Vulkan frames keeps all $MAIN_N frames"
    else fail "late second input on Vulkan frames (want $MAIN_N, got $LATE_VK)"; cat "$CLIPS/last.log"; fi
    # yuva420p: FFmpeg cannot make storage images of it, so the output falls back to rgba.
    YUVA_VK=$(vk_ff -i "$A" -frames:v 3 -an -vf "format=yuva420p,hwupload,gpufx=effect=$FX/invert.zip,hwdownload,format=rgba" \
        -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')
    same "yuva420p in, rgba Vulkan frames out" "$YUVA_VK" "$("$FF" -hide_banner -nostdin -v error -i "$A" -frames:v 3 -an -vf "format=yuva420p,gpufx=effect=$FX/invert.zip,format=rgba" \
            -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}')"
    # shellcheck disable=SC2086
    rejects "Vulkan and software inputs mixed" "mix Vulkan and software frames" -init_hw_device "$VKDEV" -filter_hw_device vk \
        -i "$A" -i "$B" -an -filter_complex "[0]format=rgba,hwupload[a];[1]format=rgba[b];[a][b]gpufx=effect=$FX/crossfade.zip" $NULL
    # shellcheck disable=SC2086
    rejects "Vulkan input, software output" "software frames but the inputs have Vulkan" -init_hw_device "$VKDEV" -filter_hw_device vk \
        -i "$A" -an -vf "format=rgba,hwupload,gpufx=effect=$FX/invert.zip,format=rgba" $NULL
    # Without disable_multiplane an nv12 frame may be one multiplane image: refused clearly
    # (or, where the driver has no multiplane nv12, processed).
    if "$FF" -hide_banner -nostdin -v error -init_hw_device vulkan=vk:0 -filter_hw_device vk -i "$A" -frames:v 2 -an \
        -vf "format=nv12,hwupload,gpufx=effect=$FX/invert.zip,hwdownload,format=nv12" -f null - > "$CLIPS/last.log" 2>&1 ||
        grep -q "multiplane images are not supported" "$CLIPS/last.log"; then
        pass "multiplane nv12 is processed or refused clearly"
    else
        fail "multiplane nv12 is processed or refused clearly"; cat "$CLIPS/last.log"
    fi
fi

echo "D3D12 and D3D11 frames:"
# hwupload -> gpufx -> hwdownload on FFmpeg's D3D12 device (D3D11: on the D3D12 device of
# its adapter), same pixels as the software path. The device is tried on adapters 0-3:
# wgpu skips the headless "Microsoft Basic Render Driver" duplicate of WARP.
dx_md5() {
    f=$1; shift
    "$FF" -hide_banner -nostdin -v error -init_hw_device "$DXDEV" -filter_hw_device dx -i "$A" -frames:v 3 -an \
        -vf "format=$f,hwupload,$1,hwdownload,format=$f" -pix_fmt "$f" -f framemd5 - \
        2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $NF}'
}
# REQUIRE_D3D=1 (the Windows CI job): a skipped API is a failure, unless FFmpeg itself
# cannot create the device on any adapter (hosted runners: WARP only, d3d12va -22,
# d3d11va DXGI_ERROR_UNSUPPORTED), since gpufx is never reached then.
dx_ran= dx_skipped=
dx_skip() {
    echo "  skip  $1"
    if [ "${2:-}" = nodevice ]; then
        dx_skipped="$dx_skipped $API(no device)"
        if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::D3D12/D3D11 frames not tested: $1"; fi
    else
        dx_skipped="$dx_skipped $API"
        if [ "${REQUIRE_D3D:-0}" = 1 ]; then fail "REQUIRE_D3D=1: $API frames were not tested"; fi
    fi
}
dx_hwdevs=$("$FF" -hide_banner -init_hw_device list 2>&1)
for api in d3d12va d3d11va; do
    API=$(echo "$api" | sed 's/va$//' | tr a-z A-Z)
    if ! grep -qw hwupload "$CLIPS/filters.txt"; then dx_skip "$API: this bundle has no hwupload"; continue; fi
    if ! echo "$dx_hwdevs" | grep -qx "$api"; then dx_skip "$API: this ffmpeg has no $api hwdevice"; continue; fi
    DXDEV= why= dx_dev=
    for n in 0 1 2 3; do
        if ! "$FF" -hide_banner -nostdin -v error -init_hw_device "$api=dx:$n" -filter_hw_device dx -i "$A" -frames:v 1 -an \
            -vf "format=nv12,hwupload,hwdownload,format=nv12" -f null - > "$CLIPS/last.log" 2>&1; then
            # Only a failed device creation means "no device here"; anything else is a bug.
            if ! grep -qi "Device creation failed\|Failed to create Direct3D device\|-22\|887a0004" "$CLIPS/last.log"; then
                fail "$API: hwupload/hwdownload probe on adapter $n"; cat "$CLIPS/last.log"; dx_dev=1 why=; break
            fi
            [ -n "$why" ] || why="$(head -n1 "$CLIPS/last.log")"
            continue
        fi
        dx_dev=1
        if "$FF" -hide_banner -nostdin -v error -init_hw_device "$api=dx:$n" -filter_hw_device dx -i "$A" -frames:v 1 -an \
            -vf "format=nv12,hwupload,gpufx=effect=$FX/invert.zip,hwdownload,format=nv12" -f null - > "$CLIPS/last.log" 2>&1; then
            DXDEV="$api=dx:$n"; break
        fi
        cp "$CLIPS/last.log" "$CLIPS/$api-$n.log"
        why="gpufx on adapter $n: $(grep -m1 -i "gpufx\|error\|impossible" "$CLIPS/last.log")"
        # A gpufx without these frames, or an adapter wgpu cannot share: try the next one.
        grep -q "Impossible to convert\|No format\|negotiat\|only supported on Windows\|not one wgpu uses\|another ID3D12Device\|no shared fences\|has no fences" \
            "$CLIPS/last.log" || { fail "$API: gpufx takes $API frames"; cat "$CLIPS/last.log"; why=; break; }
    done
    if [ -z "$DXDEV" ]; then
        if [ -z "$dx_dev" ]; then
            dx_skip "$API: FFmpeg cannot create a $api device on this machine ($why)" nodevice
        elif [ -n "$why" ]; then
            dx_skip "$API: $why"
        fi
        continue
    fi
    echo "  ($API on ${DXDEV#*=})"; dx_ran="$dx_ran $API"
    for f in nv12 p010le; do
        same "$API $f: vignette equals the software path" \
            "$(dx_md5 $f "gpufx=effect=$FX/vignette.zip:params='strength=0.7'")" \
            "$(sw_md5 $f "gpufx=effect=$FX/vignette.zip:params='strength=0.7'")"
    done
    # Two gpufx in a row: the second waits for the first (fences).
    same "$API: invert twice equals the software path" \
        "$(dx_md5 nv12 "gpufx=effect=$FX/invert.zip,gpufx=effect=$FX/invert.zip")" \
        "$(sw_md5 nv12 "gpufx=effect=$FX/invert.zip,gpufx=effect=$FX/invert.zip")"
    # One frame on two input pads (split before gpufx).
    G="[0]split[a][b]; [a]$FX/gaussian-blur.zip[ba]; [b]$FX/grayscale.zip|$FX/vignette.zip[gb]; [ba][gb]$FX/crossfade.zip[x]; [x][1]$FX/wipe-transition.zip[out]"
    same "$API: graph equals the software path" \
        "$(dx_md5 nv12 "split[p][q];[p][q]gpufx=graph='$G':params='x.progress=0.4|out.progress=0.6'")" \
        "$(sw_md5 nv12 "split[p][q];[p][q]gpufx=graph='$G':params='x.progress=0.4|out.progress=0.6'")"
    # shellcheck disable=SC2086
    ok "$API: timeline enable" -init_hw_device "$DXDEV" -filter_hw_device dx -i "$A" -an \
        -vf "format=nv12,hwupload,gpufx=effect=$FX/invert.zip:enable='gte(t\,0.5)',hwdownload,format=nv12" $NULL
    LATE_DX=$("$FF" -hide_banner -nostdin -v error -init_hw_device "$DXDEV" -filter_hw_device dx -i "$A" -itsoffset 0.5 -i "$B" -an -filter_complex \
        "[0]format=nv12,hwupload[a];[1]format=nv12,hwupload[b];[a][b]gpufx=effect=$FX/crossfade.zip:params='progress=0.5',hwdownload,format=nv12" \
        -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | wc -l | tr -d ' ')
    if [ "$LATE_DX" = "$MAIN_N" ]; then pass "$API: late second input keeps all $MAIN_N frames"
    else fail "$API: late second input (want $MAIN_N, got $LATE_DX)"; cat "$CLIPS/last.log"; fi
    # shellcheck disable=SC2086
    rejects "$API and software inputs mixed" "mix $API and software frames" -init_hw_device "$DXDEV" -filter_hw_device dx \
        -i "$A" -i "$B" -an -filter_complex "[0]format=nv12,hwupload[a];[1]format=nv12[b];[a][b]gpufx=effect=$FX/crossfade.zip" $NULL
done
echo "  D3D frames tested:${dx_ran:- none}; skipped:${dx_skipped:- none}"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
