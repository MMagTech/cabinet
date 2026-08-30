#!/bin/sh
# Builds PPSSPP's bundled ffmpeg for Mac Catalyst, into
# spikes/cores/ppsspp/src/ffmpeg/macabi/arm64.
#
# Upstream ships prebuilt ffmpeg for ios/universal and tvos/arm64 and a
# script for macOS, but nothing for macabi, and that gap is the only
# reason PSP shipped to the Mac as a link stub. The macOS archives are
# not a substitute: an arm64-apple-macos object cannot be linked into a
# Catalyst binary.
#
# So this is upstream's own mac-build.sh with the target swapped, the
# same rewrite build-core.sh performs for every other core: the macOS
# SDK, and every compile and link carrying arm64-apple-ios18.0-macabi.
# One arch, because the app is arm64 only.
#
# The codec set is upstream's shared_options.sh untouched. atrac3 and
# atrac3p in particular are what most PSP games use for music, so
# dropping ffmpeg entirely (USE_FFMPEG=OFF) would have cost audio in
# most of the library, not just cutscene video.
set -e
cd "$(dirname "$0")/.."

FF=spikes/cores/ppsspp/src/ffmpeg
[ -d "$FF" ] || { echo "no ffmpeg tree at $FF" >&2; exit 1; }

SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=arm64-apple-ios18.0-macabi
PREFIX=macabi/arm64

cd "$FF"
. ./shared_options.sh

rm -f config.h
./configure \
    --prefix="./$PREFIX" \
    --enable-cross-compile \
    --arch=aarch64 \
    --cc="$(xcrun -f clang)" \
    --sysroot="$SDK" \
    --extra-cflags="-target $TARGET -isysroot $SDK -D__STDC_CONSTANT_MACROS -D_DARWIN_FEATURE_CLOCK_GETTIME=0" \
    --extra-ldflags="-target $TARGET -isysroot $SDK" \
    ${CONFIGURE_OPTS} \
    --target-os=darwin \
    --cpu=generic \
    --enable-pic

make clean
make -j"$(sysctl -n hw.ncpu)" install
echo "Wrote $FF/$PREFIX/lib"
