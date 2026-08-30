#!/bin/sh
# Builds a link-placeholder lib<name>_mac.a for a core whose real Mac
# build is not ready (today: the GL trio, whose real builds wait on
# ANGLE-for-Mac). See tools/mac-support/stub_core.c for what the
# stub is and why it is safe. Usage:
#   tools/build-mac-core-stub.sh <prefix> <OutDirName> <libname>
# e.g.
#   tools/build-mac-core-stub.sh dc Flycast libflycast_mac.a
set -e
cd "$(dirname "$0")/.."

PREFIX=$1
OUTNAME=$2
LIB=$3
[ -n "$PREFIX" ] && [ -n "$OUTNAME" ] && [ -n "$LIB" ] || {
    echo "usage: $0 <prefix> <OutDirName> <libname>" >&2; exit 1; }

SDK=$(xcrun -sdk macosx --show-sdk-path)
WORK=tools/mac-support
OUTDIR=RommApp/RommApp/Native/$OUTNAME

cc -target arm64-apple-ios18.0-macabi -isysroot "$SDK" -O2 \
    -DCORE_PREFIX="$PREFIX" \
    -I"RommApp/RommApp/Native/Libretro" \
    -c "$WORK/stub_core.c" -o "/tmp/stub_$PREFIX.o"

mkdir -p "$OUTDIR"
rm -f "$OUTDIR/$LIB"
ar rcs "$OUTDIR/$LIB" "/tmp/stub_$PREFIX.o"
echo "Wrote $OUTDIR/$LIB (placeholder)"
