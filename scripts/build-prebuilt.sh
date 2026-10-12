#!/bin/sh
# Fast build: takes a prebuilt shared FFmpeg from tqk2811/FFmpegBuild, rebuilds only
# libavfilter (with gpufx and the short filter list of docker/keep-filters.txt) from
# the external/FFmpeg submodule, and swaps it into the bundle. Every other library and
# the ffmpeg/ffprobe executables stay the prebuilt ones. Takes a few minutes.
#
#   scripts/build-prebuilt.sh [linux64|win64]        default linux64
#
# Environment (defaults match the commit external/FFmpeg is pinned to):
#   FFBUILD_TAG      release tag             Release-2026-08-10
#   FFBUILD_VERSION  FFmpeg version string   n9.0-2-g03d9533176
#   FFBUILD_LICENSE  lgpl | gpl | lgpl2 | gpl2   lgpl
# Output: dist/<target>/ (bin, lib on Linux, effects/*.zip, include/gpufx.h)
# Needs: cargo, a C compiler, make, pkg-config, curl, patchelf (linux64), nasm (optional,
# for SIMD); win64 also mingw-w64, the x86_64-pc-windows-gnu Rust target and unzip.
set -eu
TARGET=${1:-linux64}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG=${FFBUILD_TAG:-Release-2026-08-10}
VERSION=${FFBUILD_VERSION:-n9.0-2-g03d9533176}
LICENSE=${FFBUILD_LICENSE:-lgpl}
WORK=$ROOT/build/prebuilt-$TARGET
OUT=$ROOT/dist/$TARGET
JOBS=$(nproc 2>/dev/null || echo 4)

case "$TARGET" in
    linux64) RUST_TARGET= ; EXT=tar.xz; CROSS= ;;
    win64)   RUST_TARGET=x86_64-pc-windows-gnu; EXT=zip
             CROSS="--target-os=mingw32 --arch=x86_64 --enable-cross-compile --cross-prefix=x86_64-w64-mingw32- --pkg-config=pkg-config --extra-ldflags=-static-libgcc"
             export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=${CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER:-x86_64-w64-mingw32-gcc} ;;
    *) echo "unknown target $TARGET (linux64, win64)" >&2; exit 1 ;;
esac
case "$LICENSE" in
    lgpl) LICENSE_FLAGS=--enable-version3 ;;
    gpl) LICENSE_FLAGS="--enable-gpl --enable-version3" ;;
    lgpl2) LICENSE_FLAGS= ;;
    gpl2) LICENSE_FLAGS=--enable-gpl ;;
    *) echo "unknown license $LICENSE (lgpl, gpl, lgpl2, gpl2)" >&2; exit 1 ;;
esac
# e.g. ffmpeg-n9.0-2-g03d9533176-linux64-lgpl-shared-9.0
NAME=ffmpeg-$VERSION-$TARGET-$LICENSE-shared-$(echo "$VERSION" | sed 's/^n\([0-9]*\.[0-9]*\).*/\1/')
URL=https://github.com/tqk2811/FFmpegBuild/releases/download/$TAG/$NAME.$EXT

# libavfilter must come from the same commit as the prebuilt libraries.
SRC=$ROOT/external/FFmpeg
[ -f "$SRC/configure" ] || git -C "$ROOT" submodule update --init --depth 1 external/FFmpeg
# The commit comes from the git-describe version (n9.0-2-g<sha>); FFBUILD_COMMIT overrides
# it for prebuilts named after a plain tag.
WANT=${FFBUILD_COMMIT:-${VERSION##*-g}}
[ "$WANT" != "$VERSION" ] || {
    echo "cannot read a commit from FFBUILD_VERSION=$VERSION; set FFBUILD_COMMIT" >&2; exit 1; }
HAVE=$(git -C "$SRC" rev-parse HEAD)
case "$HAVE" in
    "$WANT"*) ;;
    *) echo "external/FFmpeg is at $HAVE but the prebuilt is $VERSION; check out $WANT" >&2; exit 1 ;;
esac
if [ "$TARGET" = linux64 ] && ! command -v patchelf >/dev/null; then
    echo "patchelf is required: libavfilter must find libgpufx.so next to it" >&2; exit 1
fi

mkdir -p "$WORK"
echo "==> prebuilt FFmpeg: $NAME"
if [ ! -f "$WORK/$NAME.$EXT" ]; then
    curl -fL --retry 3 -o "$WORK/$NAME.$EXT.part" "$URL"
    mv "$WORK/$NAME.$EXT.part" "$WORK/$NAME.$EXT"
fi
rm -rf "$OUT" "${WORK:?}/$NAME"
mkdir -p "$OUT"
case $EXT in
    tar.xz) tar -C "$WORK" -xf "$WORK/$NAME.$EXT" ;;
    zip) unzip -q -o "$WORK/$NAME.$EXT" -d "$WORK" ;;
esac
cp -R "$WORK/$NAME/." "$OUT/"

echo "==> libgpufx"
"$ROOT/scripts/install-libgpufx.sh" "$WORK/prefix" $RUST_TARGET

echo "==> libavfilter (gpufx + docker/keep-filters.txt)"
rm -rf "$WORK/ffmpeg"
mkdir -p "$WORK/ffmpeg"
tar -C "$SRC" --exclude=.git -cf - . | tar -C "$WORK/ffmpeg" -xf -
"$ROOT/ffmpeg/integrate.sh" "$WORK/ffmpeg"
FILTERS=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$ROOT/docker/keep-filters.txt" | tr '\n' ',' | sed 's/,$//')
cd "$WORK/ffmpeg"
# Only libavfilter is kept. With these filters it links to avutil, swscale and swresample
# alone, so avcodec/avformat/avdevice are not built. SIMD needs nasm.
ASM=
command -v nasm >/dev/null || { ASM=--disable-x86asm; echo "    nasm not found: building without SIMD"; }
# shellcheck disable=SC2086
PKG_CONFIG_LIBDIR="$WORK/prefix/lib/pkgconfig" ./configure \
    --enable-shared --disable-static $LICENSE_FLAGS $ASM \
    --disable-programs --disable-doc --disable-debug --disable-autodetect \
    --disable-avdevice --disable-avformat --disable-avcodec \
    --disable-everything --enable-filter="$FILTERS" --enable-libgpufx \
    $CROSS > "$WORK/configure.log" || { tail -20 "$WORK/configure.log"; exit 1; }
make -j"$JOBS" > "$WORK/make.log" 2>&1 || { tail -40 "$WORK/make.log"; exit 1; }

echo "==> bundle $OUT"
if [ "$TARGET" = win64 ]; then
    DLL=$(cd libavfilter && ls avfilter-*.dll)
    [ -f "$OUT/bin/$DLL" ] || { echo "prebuilt has no bin/$DLL: ABI major differs" >&2; exit 1; }
    # Same export check as on Linux, from the PE export name table.
    exports() {
        x86_64-w64-mingw32-objdump -p "$1" | sed -n '/Ordinal\/Name Pointer/,/^$/p' |
            awk '/\[ *[0-9]+\]/ {print $NF}' | sort -u
    }
    exports "libavfilter/$DLL" > "$WORK/new-exports.txt"
    MISSING=$(exports "$OUT/bin/$DLL" | comm -23 - "$WORK/new-exports.txt")
    [ -z "$MISSING" ] || { echo "new $DLL lacks prebuilt exports: $MISSING" >&2; exit 1; }
    cp "libavfilter/$DLL" "$OUT/bin/$DLL"
    cp "$WORK/prefix/bin/gpufx.dll" "$OUT/bin/"
else
    SO=$(cd libavfilter && ls libavfilter.so.* | head -n1)
    [ -e "$OUT/lib/$SO" ] || { echo "prebuilt has no lib/$SO: ABI major differs" >&2; exit 1; }
    # lib/libavfilter.so.N is a symlink to the versioned file: replace the real file.
    REAL=$(cd "$OUT/lib" && readlink "$SO" || echo "$SO")
    # Every symbol the prebuilt programs and libraries take from libavfilter must still
    # be exported (same ABI version node, same API).
    exports() { nm -D --defined-only "$1" | awk '{print $NF}' | sort -u; }
    exports "libavfilter/$SO" > "$WORK/new-exports.txt"
    MISSING=$(exports "$OUT/lib/$REAL" | comm -23 - "$WORK/new-exports.txt")
    [ -z "$MISSING" ] || { echo "new libavfilter lacks prebuilt exports: $MISSING" >&2; exit 1; }
    cp -L "libavfilter/$SO" "$OUT/lib/$REAL"
    cp "$WORK/prefix/lib/libgpufx.so" "$OUT/lib/"
    # libavfilter finds libgpufx.so next to itself; the prebuilt executables carry a
    # broken RPATH, so point them at ../lib. ($ORIGIN cannot go through FFmpeg's
    # configure: it expands $$ to its PID.)
    patchelf --set-rpath '$ORIGIN' "$OUT/lib/$REAL"
    for exe in "$OUT"/bin/*; do
        [ -f "$exe" ] && patchelf --set-rpath '$ORIGIN/../lib' "$exe"
    done
fi
mkdir -p "$OUT/include"
cp "$ROOT/crates/gpufx-ffi/include/gpufx.h" "$OUT/include/"
cp "$ROOT/LICENSE" "$OUT/LICENSE-gpufx.txt"
"$ROOT/scripts/pack-effects.sh" -o "$OUT/effects" > /dev/null
echo "==> done: $OUT ($(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$ROOT/docker/keep-filters.txt" | wc -l) filters)"
