#!/bin/bash
# Runs inside the build image: builds libgpufx, then FFmpeg (from the external/FFmpeg
# submodule) with gpufx and without FFmpeg's built-in video filters, and writes a
# ready-to-run bundle to /out/$TARGET.
#
# Expects: /src = this repository (read-only is fine), /out = output dir,
#          TARGET = linux64 | win64, optional HOST_UID/HOST_GID to chown the output.
set -euo pipefail

SRC=/src
WORK=/build
OUT=/out/$TARGET
PREFIX=$WORK/prefix
export CARGO_TARGET_DIR=$WORK/cargo-target

case "$TARGET" in
    linux64)
        RUST_TARGET=x86_64-unknown-linux-gnu
        EXE=
        CONFIGURE_TARGET=()
        ;;
    win64)
        RUST_TARGET=x86_64-pc-windows-gnu
        EXE=.exe
        CONFIGURE_TARGET=(--target-os=mingw32 --arch=x86_64 --enable-cross-compile
                          --cross-prefix=x86_64-w64-mingw32- --pkg-config=pkg-config
                          --extra-ldflags=-static-libgcc)
        ;;
    *) echo "unknown TARGET '$TARGET' (linux64, win64)" >&2; exit 1 ;;
esac

[ -f "$SRC/external/FFmpeg/configure" ] || {
    echo "external/FFmpeg is empty: run 'git submodule update --init --depth 1'" >&2; exit 1; }

echo "==> libgpufx ($RUST_TARGET)"
rm -rf "$PREFIX"
"$SRC/scripts/install-libgpufx.sh" "$PREFIX" "$RUST_TARGET"
cargo build --release --locked --manifest-path "$SRC/Cargo.toml" -p gpufx-cli --target "$RUST_TARGET"

echo "==> FFmpeg source"
rm -rf "$WORK/ffmpeg"
mkdir -p "$WORK/ffmpeg"
# Copy instead of building in the submodule so the checkout stays pristine.
tar -C "$SRC/external/FFmpeg" --exclude=.git -cf - . | tar -C "$WORK/ffmpeg" -xf -
"$SRC/ffmpeg/integrate.sh" "$WORK/ffmpeg"

# Every audio filter plus the short list of video filters in keep-filters.txt.
AUDIO=$(sed -n 's/^extern const FFFilter ff_\(af\|asrc\|asink\)_\([a-z0-9_]*\);$/\2/p' \
        "$WORK/ffmpeg/libavfilter/allfilters.c")
KEEP=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$SRC/docker/keep-filters.txt")
FILTERS=$(echo $AUDIO $KEEP | tr ' ' ',')
echo "    $(echo $AUDIO | wc -w) audio filters, video filters: $(echo $KEEP | tr '\n' ' ')"

# gpufx outputs GPU frames only: FFmpeg needs Vulkan (hwcontext_vulkan), which wants
# vulkan.h >= 1.3.277, newer than the distro packages. The loader is opened at run time.
VK_TAG=${VULKAN_HEADERS_TAG:-v1.4.321}
VK_HDR=$WORK/Vulkan-Headers-${VK_TAG#v}
if [ ! -f "$VK_HDR/include/vulkan/vulkan.h" ]; then
    echo "==> Vulkan-Headers $VK_TAG"
    curl -sSfL "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/$VK_TAG.tar.gz" | tar -C "$WORK" -xzf -
fi

# FFmpeg's exr decoder/encoder need zlib; configure drops them silently without it, so
# --enable-zlib below makes a missing zlib a hard error. linux64 links the image's
# zlib1g-dev; win64 has no mingw zlib package, so build a static one into the prefix.
if [ "$TARGET" = win64 ]; then
    ZLIB_VER=${ZLIB_VERSION:-1.3.1}
    echo "==> zlib $ZLIB_VER (static, mingw)"
    rm -rf "$WORK/zlib-$ZLIB_VER"
    curl -sSfL "https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.gz" | tar -C "$WORK" -xzf -
    (cd "$WORK/zlib-$ZLIB_VER" \
        && CHOST=x86_64-w64-mingw32 ./configure --static --prefix="$PREFIX" \
        && make -j"$(nproc)" && make install)
fi

echo "==> configure FFmpeg ($TARGET)"
cd "$WORK/ffmpeg"
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" ./configure \
    --prefix="$WORK/ffmpeg-install" \
    --extra-version=gpufx \
    --disable-doc --disable-debug --disable-ffplay \
    --enable-libgpufx --enable-zlib \
    --enable-vulkan --extra-cflags="-I$VK_HDR/include" \
    --disable-filters --enable-filter="$FILTERS" \
    ${CONFIGURE_TARGET[@]+"${CONFIGURE_TARGET[@]}"}

echo "==> build FFmpeg"
make -j"$(nproc)"
make install

echo "==> bundle $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/effects"
cp "$WORK/ffmpeg-install/bin/ffmpeg$EXE" "$WORK/ffmpeg-install/bin/ffprobe$EXE" "$OUT/bin/"
cp "$CARGO_TARGET_DIR/$RUST_TARGET/release/gpufx$EXE" "$OUT/bin/gpufx-cli$EXE"
if [ "$TARGET" = win64 ]; then
    cp "$PREFIX/bin/gpufx.dll" "$OUT/bin/"
else
    cp "$PREFIX/lib/libgpufx.so" "$OUT/bin/"
    # Find libgpufx.so next to the executables wherever the bundle is unpacked.
    patchelf --set-rpath '$ORIGIN' "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe"
fi
cp -r "$PREFIX/include" "$OUT/"
for dir in "$SRC"/examples/effects/*/; do
    name=$(basename "$dir")
    (cd "$dir" && zip -qr "$OUT/effects/$name.zip" .)
done
cp "$SRC/README.md" "$SRC/README-vi.md" "$OUT/"
cp "$SRC/LICENSE" "$OUT/LICENSE-gpufx.txt"
"$SRC/scripts/third-party-licenses.sh" "$OUT/THIRD-PARTY-LICENSES-gpufx.txt" "$RUST_TARGET"
cp "$WORK/ffmpeg/COPYING.LGPLv2.1" "$OUT/FFMPEG-LICENSE.txt"

if [ -n "${HOST_UID:-}" ]; then
    chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT"
fi
echo "==> done: $OUT"
