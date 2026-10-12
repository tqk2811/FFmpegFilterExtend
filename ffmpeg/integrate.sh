#!/bin/sh
# Adds the gpufx filter to an FFmpeg source tree (tested with n9.0.2 and the
# external/FFmpeg submodule, 9.1-dev). build.sh runs this for you inside Docker.
#   ffmpeg/integrate.sh /path/to/FFmpeg
# Then: ./configure --enable-libgpufx ... (libgpufx must be found by pkg-config)
# This is a one-time step: new effects are packages, not FFmpeg rebuilds.
set -eu
SRC=${1:?usage: integrate.sh /path/to/FFmpeg}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$SRC"
[ -f libavfilter/allfilters.c ] || { echo "$SRC is not an FFmpeg source tree" >&2; exit 1; }

cp "$HERE/vf_gpufx.c" libavfilter/vf_gpufx.c

if grep -q libgpufx configure; then
    echo "configure already knows libgpufx; refreshed vf_gpufx.c only"
    exit 0
fi

# Anchor every edit on the matching libplacebo line, which exists in all recent FFmpeg.
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

sed -i.bak 's/^\(OBJS-$(CONFIG_GRADFUN_FILTER) .*\)$/\1\
OBJS-$(CONFIG_GPUFX_FILTER)                  += vf_gpufx.o framesync.o/' libavfilter/Makefile
sed -i.bak 's/^\(extern const FFFilter ff_vf_gradfun;\)$/\1\
extern const FFFilter ff_vf_gpufx;/' libavfilter/allfilters.c
rm -f libavfilter/Makefile.bak libavfilter/allfilters.c.bak
grep -q CONFIG_GPUFX_FILTER libavfilter/Makefile && grep -q ff_vf_gpufx libavfilter/allfilters.c \
    || { echo "patching libavfilter failed" >&2; exit 1; }
echo "gpufx filter added; configure FFmpeg with --enable-libgpufx"
