#!/bin/sh
# Builds libgpufx and installs the library, header and gpufx.pc under PREFIX.
#   scripts/install-libgpufx.sh [PREFIX] [RUST_TARGET]
# PREFIX defaults to /usr/local; RUST_TARGET (e.g. x86_64-pc-windows-gnu) to the host.
# Then build FFmpeg with PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig.
set -eu
PREFIX=${1:-/usr/local}
RUST_TARGET=${2:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -n1)
TARGET_DIR=${CARGO_TARGET_DIR:-$ROOT/target}

if [ -n "$RUST_TARGET" ]; then
    cargo build --release --locked --manifest-path "$ROOT/Cargo.toml" -p gpufx-ffi --target "$RUST_TARGET"
    OUT="$TARGET_DIR/$RUST_TARGET/release"
else
    cargo build --release --locked --manifest-path "$ROOT/Cargo.toml" -p gpufx-ffi
    OUT="$TARGET_DIR/release"
fi

case "${RUST_TARGET:-$(uname -s)}" in
    *windows-gnu*|MINGW*|MSYS*|CYGWIN*) KIND=mingw ;;
    *windows-msvc*) KIND=msvc ;;
    *apple*|Darwin) KIND=macos ;;
    *) KIND=elf ;;
esac

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/bin"
cp "$ROOT/crates/gpufx-ffi/include/gpufx.h" "$PREFIX/include/"
# Only the shared library and its import library are installed (never libgpufx.a), so
# FFmpeg links libgpufx dynamically and needs no Rust runtime link flags.
case $KIND in
    mingw)
        cp "$OUT/gpufx.dll" "$PREFIX/bin/"
        cp "$OUT/libgpufx.dll.a" "$PREFIX/lib/" ;;
    msvc)
        cp "$OUT/gpufx.dll" "$PREFIX/bin/"
        cp "$OUT/gpufx.dll.lib" "$PREFIX/lib/gpufx.lib" ;;
    macos) cp "$OUT/libgpufx.dylib" "$PREFIX/lib/" ;;
    elf) cp "$OUT/libgpufx.so" "$PREFIX/lib/" ;;
esac

cat > "$PREFIX/lib/pkgconfig/gpufx.pc" <<PC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: gpufx
Description: GPU effect packages (manifest + WGSL/GLSL) for FFmpeg
Version: $VERSION
Libs: -L\${libdir} -lgpufx
Cflags: -I\${includedir}
PC
echo "installed libgpufx $VERSION ($KIND) to $PREFIX"
