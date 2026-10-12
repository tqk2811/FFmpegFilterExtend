#!/bin/sh
# Builds libgpufx and installs the library, header and gpufx.pc under PREFIX.
#   scripts/install-libgpufx.sh [PREFIX]      (default: /usr/local)
# Then build FFmpeg with PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig.
set -eu
PREFIX=${1:-/usr/local}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -n1)

cargo build --release --manifest-path "$ROOT/Cargo.toml" -p gpufx-ffi

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include"
cp "$ROOT/crates/gpufx-ffi/include/gpufx.h" "$PREFIX/include/"
case "$(uname -s)" in
    Darwin) cp "$ROOT/target/release/libgpufx.dylib" "$PREFIX/lib/" ;;
    MINGW*|MSYS*|CYGWIN*)
        cp "$ROOT/target/release/gpufx.dll" "$PREFIX/lib/"
        cp "$ROOT/target/release/gpufx.dll.lib" "$PREFIX/lib/gpufx.lib" ;;
    *) cp "$ROOT/target/release/libgpufx.so" "$PREFIX/lib/" ;;
esac

cat > "$PREFIX/lib/pkgconfig/gpufx.pc" <<PC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: gpufx
Description: GPU effect packages (manifest + WGSL) for FFmpeg
Version: $VERSION
Libs: -L\${libdir} -lgpufx
Cflags: -I\${includedir}
PC
echo "installed libgpufx $VERSION to $PREFIX"
