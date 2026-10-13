#!/bin/sh
# Writes the licenses of the Rust crates that libgpufx and gpufx-cli link against
# (cargo about, about.toml + about.hbs) to one text file shipped in the bundle.
#
#   scripts/third-party-licenses.sh OUTPUT [RUST_TARGET]
#
# Without cargo-about it prints a warning and writes nothing; REQUIRE_LICENSES=1 makes
# that an error (CI). Install: cargo install --locked cargo-about
set -eu
OUTPUT=${1:?usage: third-party-licenses.sh OUTPUT [RUST_TARGET]}
RUST_TARGET=${2:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if ! cargo about --version > /dev/null 2>&1; then
    if [ "${REQUIRE_LICENSES:-0}" = 1 ]; then
        echo "REQUIRE_LICENSES=1: cargo-about is not installed" >&2; exit 1
    fi
    echo "    cargo-about not installed: $(basename "$OUTPUT") is not written"
    exit 0
fi
# Every workspace crate (gpufx-ffi, gpufx-cli); about.toml leaves out dev and build
# dependencies.
cd "$ROOT"
cargo about generate --locked --workspace \
    ${RUST_TARGET:+--target "$RUST_TARGET"} -o "$OUTPUT" about.hbs
