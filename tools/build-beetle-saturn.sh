#!/bin/sh
# Builds RommApp/RommApp/Native/Saturn/libbeetle_saturn_ios.a from the
# libretro Beetle Saturn sources.
#
# The shape of the output matters more than the compile: FBNeo already
# links under the standard retro_* symbol names and two cores cannot
# both export them. Apple's toolchain ships no object-file symbol
# renamer, so the rename happens in C: bsat_wrapper.c defines a
# bsat_retro_* forwarder for each of the 25 libretro entry points, and
# `ld -r -exported_symbols_list` merges the wrapper plus every core
# object into one relocatable object whose only exported symbols are
# the bsat_* names. Everything else, the real retro_* included, along
# with the core's bundled zlib, lzma, zstd and libretro-common, becomes
# private to the object and cannot collide with FBNeo's copies.
#
# Note: built WITHOUT STATIC_LINKING=1. That flag assumes a
# RetroArch-style frontend that provides libretro-common itself and
# skips compiling the core's own copy; this app's frontend provides
# nothing of the sort, and the dylib link the normal build runs doubles
# as proof that no symbol is missing.
set -e

cd "$(dirname "$0")/.."
SPIKE=spikes/BeetleSaturnStatic
SRC=$SPIKE/beetle-saturn-libretro
OUT=RommApp/RommApp/Native/Saturn
SDK=$(xcrun -sdk iphoneos --show-sdk-path)

if [ ! -d "$SRC" ]; then
    mkdir -p "$SPIKE"
    git clone --depth 1 https://github.com/libretro/beetle-saturn-libretro.git "$SRC"
fi

make -C "$SRC" platform=ios-arm64 -j"$(sysctl -n hw.ncpu)"

cc -arch arm64 -isysroot "$SDK" -miphoneos-version-min=18.0 -O2 \
    -I"$SRC" -c "$SPIKE/bsat_wrapper.c" -o "$SPIKE/bsat_wrapper.o"

nm -g "$SRC/mednafen_saturn_libretro_ios.dylib" 2>/dev/null \
    | awk '/ T _retro_/{print $NF}' | sed 's/^_retro_/_bsat_retro_/' | sort -u \
    > "$SPIKE/bsat_exports.txt"

find "$SRC" -name '*.o' > "$SPIKE/objects.txt"
ld -r -arch arm64 -syslibroot "$SDK" \
    "$SPIKE/bsat_wrapper.o" $(cat "$SPIKE/objects.txt") \
    -exported_symbols_list "$SPIKE/bsat_exports.txt" \
    -o "$SPIKE/beetle_saturn_combined.o"

mkdir -p "$OUT"
rm -f "$OUT/libbeetle_saturn_ios.a"
ar rcs "$OUT/libbeetle_saturn_ios.a" "$SPIKE/beetle_saturn_combined.o"
echo "Wrote $OUT/libbeetle_saturn_ios.a"
