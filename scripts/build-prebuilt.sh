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
#   VULKAN_HEADERS   directory with include/vulkan/vulkan.h (Khronos Vulkan-Headers); by
#                    default tag VULKAN_HEADERS_TAG (v1.4.321) is cloned into build/downloads.
#                    gpufx takes Vulkan frames (hwupload, -hwaccel vulkan) only when the
#                    prebuilt libavutil has Vulkan and the headers are found; otherwise the
#                    filter is built without it (a message says so).
#   MINGW_HEADERS_TAG  win64: mingw-w64 tag whose d3d12*.h headers are fetched when the
#                    installed mingw-w64 has no d3d12video.h (v12.0.0). gpufx takes D3D12
#                    and D3D11 frames when the prebuilt libavutil has d3d12va / d3d11va.
#   REQUIRE_D3D      win64: 1 makes building without D3D12/D3D11 frames an error (CI).
#   REQUIRE_LICENSES 1 makes a missing cargo-about an error (CI); without it the bundle
#                    has no THIRD-PARTY-LICENSES-gpufx.txt (the Rust crate licenses).
# Output: dist/<target>/ (bin, lib on Linux, effects/*.zip, include/gpufx.h)
# Needs: cargo (cargo-about for the crate licenses), a C compiler, make, pkg-config, curl, patchelf (linux64), nasm (optional,
# for SIMD); win64 also mingw-w64, binutils (strings), the x86_64-pc-windows-gnu Rust target and unzip.
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

mkdir -p "$WORK" "$ROOT/build/downloads"
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

# Vulkan frames need Vulkan in the prebuilt libavutil (hwcontext_vulkan) and the headers
# here: FFmpeg wants vulkan.h >= 1.3.277, newer than Ubuntu noble's libvulkan-dev.
VULKAN=
if [ "$TARGET" = win64 ]; then
    VK_LIB=$(ls "$OUT"/bin/avutil-*.dll 2>/dev/null | head -n1)
    vk_exports() { x86_64-w64-mingw32-objdump -p "$1" | grep -c av_vk_frame_alloc || true; }
else
    VK_LIB=$(ls "$OUT"/lib/libavutil.so.* 2>/dev/null | head -n1)
    vk_exports() { nm -D --defined-only "$1" | grep -c av_vk_frame_alloc || true; }
fi
if [ -z "$VK_LIB" ] || [ "$(vk_exports "$VK_LIB")" = 0 ]; then
    echo "    prebuilt libavutil has no Vulkan: gpufx is built without Vulkan frames"
else
    VK_TAG=${VULKAN_HEADERS_TAG:-v1.4.321}
    VK_HDR=${VULKAN_HEADERS:-$ROOT/build/downloads/Vulkan-Headers-$VK_TAG}
    if [ ! -f "$VK_HDR/include/vulkan/vulkan.h" ] && [ -z "${VULKAN_HEADERS:-}" ]; then
        rm -rf "$VK_HDR.part"
        git -c advice.detachedHead=false clone -q --depth 1 --branch "$VK_TAG" https://github.com/KhronosGroup/Vulkan-Headers "$VK_HDR.part" &&
            mv "$VK_HDR.part" "$VK_HDR" || echo "    cannot fetch Vulkan-Headers $VK_TAG"
    fi
    if [ -f "$VK_HDR/include/vulkan/vulkan.h" ]; then
        VULKAN="--enable-vulkan --extra-cflags=-I$VK_HDR/include"
        echo "    Vulkan frames: on (headers $VK_HDR)"
    else
        echo "    no Vulkan headers: gpufx is built without Vulkan frames"
    fi
fi

# D3D12/D3D11 frames (win64): the prebuilt libavutil must have hwcontext_d3d12va/d3d11va
# (the names of the device types are in it). FFmpeg's d3d12va needs d3d12video.h, which
# mingw-w64 before 12 lacks (Ubuntu noble has 11): the headers of mingw-w64 12 are fetched.
D3D=
# no_d3d MESSAGE: without D3D frames, or a hard error with REQUIRE_D3D=1.
no_d3d() {
    if [ "${REQUIRE_D3D:-0}" = 1 ]; then echo "REQUIRE_D3D=1: $1" >&2; exit 1; fi
    echo "    $1"
}
if [ "$TARGET" = win64 ]; then
    AVUTIL=$(ls "$OUT"/bin/avutil-*.dll | head -n1)
    if strings "$AVUTIL" | grep -qx D3D11VA; then
        D3D="--enable-d3d11va"
        echo "    D3D11 frames: on"
    else
        no_d3d "prebuilt libavutil has no d3d11va: gpufx is built without D3D11 frames"
    fi
    if strings "$AVUTIL" | grep -qx D3D12VA; then
        MW_TAG=${MINGW_HEADERS_TAG:-v12.0.0}
        MW_HDR=$ROOT/build/downloads/mingw-w64-headers-$MW_TAG
        # sha256 of the v12.0.0 headers; another tag is taken as it comes.
        mw_sum() {
            case $1 in
                d3d12.h) echo 736975a5cd80870fbf129c19109270f71f084e759747370ed59692c9653bcccb ;;
                d3d12sdklayers.h) echo 1252f39aa3a8ff99e0eb0f78011f7346c720464d396fea1c2a7af7ce25f54102 ;;
                d3d12video.h) echo 48fa7815de28606aafef8247014b69540bd550e97f2ff3402e515a406666ef15 ;;
            esac
        }
        have_d3d12video() { echo '#include <d3d12video.h>' | x86_64-w64-mingw32-gcc -x c -E - > /dev/null 2>&1; }
        if ! have_d3d12video && [ ! -f "$MW_HDR/d3d12video.h" ]; then
            rm -rf "$MW_HDR.part" && mkdir -p "$MW_HDR.part"
            ok=1
            for h in d3d12.h d3d12sdklayers.h d3d12video.h; do
                if ! curl -fsSL --retry 3 -o "$MW_HDR.part/$h" \
                    "https://raw.githubusercontent.com/mingw-w64/mingw-w64/$MW_TAG/mingw-w64-headers/include/$h"; then
                    echo "    cannot fetch mingw-w64 $MW_TAG $h"; ok=0; break
                fi
                if [ "$MW_TAG" = v12.0.0 ] && [ "$(sha256sum "$MW_HDR.part/$h" | cut -d' ' -f1)" != "$(mw_sum "$h")" ]; then
                    echo "    mingw-w64 $MW_TAG $h: sha256 mismatch"; ok=0; break
                fi
            done
            if [ "$ok" = 1 ]; then mv "$MW_HDR.part" "$MW_HDR"; else rm -rf "$MW_HDR.part"; fi
        fi
        if [ -f "$MW_HDR/d3d12video.h" ]; then
            D3D="$D3D --enable-d3d12va --extra-cflags=-I$MW_HDR"
            echo "    D3D12 frames: on (mingw-w64 $MW_TAG headers)"
        elif have_d3d12video; then
            D3D="$D3D --enable-d3d12va"
            echo "    D3D12 frames: on"
        else
            no_d3d "no d3d12video.h: gpufx is built without D3D12 frames"
        fi
    else
        no_d3d "prebuilt libavutil has no d3d12va: gpufx is built without D3D12 frames"
    fi
fi

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
    $VULKAN $D3D $CROSS > "$WORK/configure.log" || { tail -20 "$WORK/configure.log"; exit 1; }
if [ -n "$VULKAN" ] && ! grep -q '^#define CONFIG_VULKAN 1' config.h; then
    echo "configure did not enable Vulkan; see $WORK/configure.log" >&2; exit 1
fi
for api in D3D11VA D3D12VA; do
    case " $D3D " in *" --enable-$(echo $api | tr A-Z a-z) "*)
        grep -q "^#define CONFIG_$api 1" config.h || { echo "configure did not enable $api; see $WORK/configure.log" >&2; exit 1; } ;;
    esac
done
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
    # DXC next to ffmpeg.exe: wgpu would fall back to the slow FXC without it.
    "$ROOT/scripts/fetch-dxc.sh" "$OUT/bin"
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
"$ROOT/scripts/third-party-licenses.sh" "$OUT/THIRD-PARTY-LICENSES-gpufx.txt" "$RUST_TARGET"
"$ROOT/scripts/pack-effects.sh" -o "$OUT/effects" > /dev/null
echo "==> done: $OUT ($(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$ROOT/docker/keep-filters.txt" | wc -l) filters)"
