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

if [ ! -f "$CLIPS/d.mkv" ]; then
    REF=${REF_FFMPEG:-ffmpeg}
    "$REF" -v error -y -f lavfi -i testsrc2=s=320x180:d=1 -f lavfi -i sine=d=1 \
        -c:v ffv1 -c:a flac -shortest "$CLIPS/a.mkv"
    "$REF" -v error -y -f lavfi -i smptebars=s=320x180:d=1 -c:v ffv1 "$CLIPS/b.mkv"
    "$REF" -v error -y -f lavfi -i smptebars=s=300x180:d=1 -c:v ffv1 "$CLIPS/c.mkv"
    # Same size as a.mkv (25 fps) but 60 fps, for the frame rate test.
    "$REF" -v error -y -f lavfi -i smptebars=s=320x180:r=60:d=1 -c:v ffv1 "$CLIPS/d.mkv"
fi
[ "${TEST_CLIPS_ONLY:-0}" = 1 ] && exit 0
A=$CLIPS/a.mkv B=$CLIPS/b.mkv C=$CLIPS/c.mkv D=$CLIPS/d.mkv
if command -v cygpath >/dev/null; then   # Git Bash on Windows: give ffmpeg.exe C:/ paths
    A=$(cygpath -m "$A") B=$(cygpath -m "$B") C=$(cygpath -m "$C") D=$(cygpath -m "$D")
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
echo "single input effects (audio stream kept):"
for e in "$FX"/*.zip; do
    case $(basename "$e" .zip) in
        wipe-transition|crossfade|slide-transition|circle-reveal|overlay) continue ;;
    esac
    # shellcheck disable=SC2086
    ok "$(basename "$e" .zip)" -i "$A" -vf "gpufx=effect=$e" $NULL
done
echo "two input effects:"
for e in wipe-transition crossfade slide-transition circle-reveal; do
    # shellcheck disable=SC2086
    ok "$e" -i "$A" -i "$B" -filter_complex "[0][1]gpufx=effect=$FX/$e.zip:params='progress=t'" -an $NULL
done
# shellcheck disable=SC2086
ok "overlay (different sizes)" -i "$A" -i "$C" -filter_complex "[0][1]gpufx=effect=$FX/overlay.zip:params='border=2'" -an $NULL
echo "expressions, sendcmd, timeline, chains:"
# shellcheck disable=SC2086
ok "expression params" -i "$A" -vf "gpufx=effect=$FX/vignette.zip:params='strength=clip(t\,0\,1)|color=#ff0000'" $NULL
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

echo "frame rate:"
# The first input sets the output frame rate: a 25 fps clip mixed with a 60 fps clip must
# give exactly the 25 fps timestamps (passthrough keeps what the filter emits).
pts() {
    "$FF" -hide_banner -nostdin -v error "$@" -an -fps_mode passthrough -enc_time_base filter \
        -f framemd5 - 2> "$CLIPS/last.log" | grep -v '^#' | awk -F, '{print $3}' | tr -d ' ' | tr '\n' ' '
}
MAIN_PTS=$(pts -i "$A" -vf "format=rgba")
MIXED_PTS=$(pts -i "$A" -i "$D" -filter_complex "[0][1]gpufx=effect=$FX/crossfade.zip")
if [ -n "$MAIN_PTS" ] && [ "$MIXED_PTS" = "$MAIN_PTS" ]; then
    pass "25 fps + 60 fps input keeps the 25 fps timestamps"
else
    fail "25 fps + 60 fps input keeps the 25 fps timestamps"
    echo "    want: $MAIN_PTS"; echo "    got:  $MIXED_PTS"; cat "$CLIPS/last.log"
fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
