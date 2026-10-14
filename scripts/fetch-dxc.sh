#!/usr/bin/env bash
# Copies dxcompiler.dll (x64) of the DirectX Shader Compiler and its license texts into
# DIR. wgpu compiles shaders for Direct3D 12 with it when it finds it next to the
# executable or on the PATH; without it wgpu uses the old FXC, which takes minutes on
# loop-heavy shaders such as the falling leaves. Since DXC 1.8.2505 dxil.dll is not needed.
#
#   scripts/fetch-dxc.sh DIR
#
# Needs curl, sha256sum and unzip (or Python, as on the Windows runners). The package
# is cached in build/downloads (or $DXC_DOWNLOAD_DIR, for a read-only checkout).
set -euo pipefail

DIR=${1:?usage: fetch-dxc.sh DIR}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=1.9.2609.5
SHA256=73cfa082245918c2cc1ec6740250eb7377e83a757b3b3a3e16e0d71535bfbfc3
PKG=${DXC_DOWNLOAD_DIR:-$ROOT/build/downloads}/microsoft.direct3d.dxc.$VERSION.nupkg

if ! echo "$SHA256  $PKG" | sha256sum -c --status 2> /dev/null; then
    mkdir -p "$(dirname "$PKG")"
    curl -fsSL --retry 3 -o "$PKG.part" \
        "https://api.nuget.org/v3-flatcontainer/microsoft.direct3d.dxc/$VERSION/microsoft.direct3d.dxc.$VERSION.nupkg"
    echo "$SHA256  $PKG.part" | sha256sum -c --status || {
        echo "fetch-dxc: checksum mismatch for DXC $VERSION" >&2; rm -f "$PKG.part"; exit 1; }
    mv "$PKG.part" "$PKG"
fi
# extract MEMBER: writes one file of the package to stdout.
if command -v unzip > /dev/null; then
    extract() { unzip -q -p "$PKG" "$1"; }
else
    # The first Python that runs: Windows may have a python3 stub that does not.
    PY=
    for p in python3 python; do
        if "$p" -c '' 2> /dev/null; then PY=$p; break; fi
    done
    [ -n "$PY" ] || { echo "fetch-dxc: needs unzip or Python" >&2; exit 1; }
    extract() { "$PY" -c 'import sys, zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))' "$PKG" "$1"; }
fi
mkdir -p "$DIR"
extract build/native/bin/x64/dxcompiler.dll > "$DIR/dxcompiler.dll"
# The package is LLVM (University of Illinois/NCSA) licensed, with MIT parts and
# Microsoft terms for the binaries; ship all three texts with the DLL.
extract LICENSE-LLVM.txt > "$DIR/LICENSE-dxcompiler-LLVM.txt"
extract LICENCE-MIT.txt > "$DIR/LICENSE-dxcompiler-MIT.txt"
extract LICENSE-MS.txt > "$DIR/LICENSE-dxcompiler-MS.txt"
echo "fetch-dxc: DXC $VERSION -> $DIR"
