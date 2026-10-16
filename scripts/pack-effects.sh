#!/bin/sh
# Packs effect folders into .zip packages only: no FFmpeg, no Docker.
# Every package is validated first (manifest, rules, file references) by `gpufx pack`.
#   scripts/pack-effects.sh                       all of examples/effects -> dist/effects/<group>/<name>.zip
#   scripts/pack-effects.sh -o out my-fx other-fx  chosen folders -> out/ (group kept for examples/effects)
#   scripts/pack-effects.sh --check               also compile every shader on the GPU
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/dist/effects
CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT=${2:?-o needs a directory}; shift 2 ;;
        --check) CHECK=1; shift ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        --) shift; break ;;
        -*) echo "unknown option $1" >&2; exit 1 ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || set -- "$ROOT"/examples/effects/*/*/

cargo build --release --quiet --manifest-path "$ROOT/Cargo.toml" -p gpufx-cli
GPUFX=$ROOT/target/release/gpufx
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

for dir in "$@"; do
    dir=${dir%/}
    [ -f "$dir/manifest.json" ] || { echo "$dir: no manifest.json" >&2; exit 1; }
    [ "$CHECK" = 1 ] && "$GPUFX" check "$dir"
    # Effects of examples/effects keep their group folder (out/<group>/<name>.zip);
    # other folders are packed flat (out/<name>.zip).
    dir=$(cd "$dir" && pwd)
    case "$dir" in
        "$ROOT"/examples/effects/*) rel=${dir#"$ROOT"/examples/effects/} ;;
        *) rel=$(basename "$dir") ;;
    esac
    mkdir -p "$OUT/$(dirname "$rel")"
    "$GPUFX" pack "$dir" "$OUT/$rel.zip"
done
