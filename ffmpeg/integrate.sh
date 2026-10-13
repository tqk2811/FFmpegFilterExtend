#!/bin/sh
# Adds the gpufx filters (gpufx, gpufx_upload, gpufx_download) to an FFmpeg source tree
# (tested with the external/FFmpeg submodule, n9.0-2-g03d9533176, and 9.1-dev).
# build.sh and build-prebuilt.sh run it.
#   ffmpeg/integrate.sh /path/to/FFmpeg
# Then: ./configure --enable-libgpufx ... (libgpufx must be found by pkg-config)
# This is a one-time step: new effects are packages, not FFmpeg rebuilds.
# Each edit is skipped when already there, so a tree patched by an older version gets
# the new pieces.
set -eu
SRC=${1:?usage: integrate.sh /path/to/FFmpeg}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$SRC"
[ -f libavfilter/allfilters.c ] || { echo "$SRC is not an FFmpeg source tree" >&2; exit 1; }

cp "$HERE/vf_gpufx.c" libavfilter/vf_gpufx.c
cp "$HERE/vf_gpufx_transfer.c" libavfilter/vf_gpufx_transfer.c

# Anchor every edit on the matching libplacebo line, which exists in all recent FFmpeg.
if ! grep -q libgpufx configure; then
    sed -i.bak \
        -e 's/^\(  --enable-libplacebo .*\)$/\1\
  --enable-libgpufx        enable GPU effect packages via libgpufx [no]/' \
        -e 's/^\(    libplacebo\)$/\1\
    libgpufx/' \
        -e 's/^\(libplacebo_filter_deps=.*\)$/\1\
gpufx_filter_deps="libgpufx swscale"/' \
        -e 's/^\(enabled libplacebo .*\)$/\1\
enabled libgpufx          \&\& require_pkg_config libgpufx "gpufx >= 0.1.0" gpufx.h gpufx_version/' \
        configure
    rm -f configure.bak
    [ "$(grep -c libgpufx configure)" -ge 4 ] || { echo "patching configure failed" >&2; exit 1; }
fi
# The transfer filters use FFmpeg's Vulkan helpers only (no libgpufx).
if ! grep -q gpufx_upload_filter_deps configure; then
    sed -i.bak 's/^\(gpufx_filter_deps=.*\)$/\1\
gpufx_download_filter_deps="vulkan"\
gpufx_upload_filter_deps="vulkan"/' configure
    rm -f configure.bak
    grep -q gpufx_upload_filter_deps configure || { echo "patching configure failed" >&2; exit 1; }
fi

if ! grep -q CONFIG_GPUFX_FILTER libavfilter/Makefile; then
    sed -i.bak 's/^\(OBJS-$(CONFIG_GRADFUN_FILTER) .*\)$/\1\
OBJS-$(CONFIG_GPUFX_FILTER)                  += vf_gpufx.o framesync.o/' libavfilter/Makefile
fi
if ! grep -q CONFIG_GPUFX_UPLOAD_FILTER libavfilter/Makefile; then
    sed -i.bak 's/^\(OBJS-$(CONFIG_GPUFX_FILTER) .*\)$/\1\
OBJS-$(CONFIG_GPUFX_DOWNLOAD_FILTER)         += vf_gpufx_transfer.o vulkan.o\
OBJS-$(CONFIG_GPUFX_UPLOAD_FILTER)           += vf_gpufx_transfer.o vulkan.o/' libavfilter/Makefile
fi
if ! grep -q ff_vf_gpufx_upload libavfilter/allfilters.c; then
    grep -q 'ff_vf_gpufx;' libavfilter/allfilters.c || \
        sed -i.bak 's/^\(extern const FFFilter ff_vf_gradfun;\)$/\1\
extern const FFFilter ff_vf_gpufx;/' libavfilter/allfilters.c
    sed -i.bak 's/^\(extern const FFFilter ff_vf_gpufx;\)$/\1\
extern const FFFilter ff_vf_gpufx_download;\
extern const FFFilter ff_vf_gpufx_upload;/' libavfilter/allfilters.c
fi
rm -f libavfilter/Makefile.bak libavfilter/allfilters.c.bak
grep -q CONFIG_GPUFX_FILTER libavfilter/Makefile && grep -q CONFIG_GPUFX_UPLOAD_FILTER libavfilter/Makefile &&
    grep -q 'ff_vf_gpufx;' libavfilter/allfilters.c && grep -q ff_vf_gpufx_upload libavfilter/allfilters.c \
    || { echo "patching libavfilter failed" >&2; exit 1; }
echo "gpufx filters added; configure FFmpeg with --enable-libgpufx (gpufx_upload/download need --enable-vulkan)"
