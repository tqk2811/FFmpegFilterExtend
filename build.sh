#!/bin/sh
# One-click build of FFmpeg + gpufx in Docker.
#   ./build.sh            linux64
#   ./build.sh win64
#   ./build.sh all
# Output: dist/<target>/bin (ffmpeg, ffprobe, libgpufx, gpufx-cli) and dist/<target>/effects/<group>/<name>.zip
set -eu
cd "$(dirname "$0")"
TARGETS=${1:-linux64}
[ "$TARGETS" = all ] && TARGETS="linux64 win64"

git submodule update --init --depth 1 external/FFmpeg

for target in $TARGETS; do
    [ -f "docker/$target.Dockerfile" ] || { echo "unknown target $target (linux64, win64, all)" >&2; exit 1; }
    image="gpufx-build-$target"
    docker build -t "$image" -f "docker/$target.Dockerfile" docker
    mkdir -p dist
    # Named volumes keep the cargo registry and Rust build output between runs.
    docker run --rm \
        -e TARGET="$target" -e FFMPEG_FILTERS="${FFMPEG_FILTERS:-all}" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -v "$PWD:/src:ro" \
        -v "$PWD/dist:/out" \
        -v gpufx-cargo-registry:/opt/cargo/registry \
        -v "gpufx-work-$target:/build" \
        "$image"
done
