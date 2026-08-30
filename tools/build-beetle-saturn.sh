#!/bin/sh
# Builds RommApp/RommApp/Native/Saturn/libbeetle_saturn_<platform>.a from
# the libretro Beetle Saturn sources. Usage: tools/build-beetle-saturn.sh
# [ios|tvos], defaults to ios.
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
PLATFORM=${1:-ios}

case "$PLATFORM" in
ios)
    SDK=$(xcrun -sdk iphoneos --show-sdk-path)
    MINVERSION_FLAG=-miphoneos-version-min=18.0
    MAKE_PLATFORM=ios-arm64
    XCRUN_SDK=iphoneos ;;
tvos)
    SDK=$(xcrun -sdk appletvos --show-sdk-path)
    MINVERSION_FLAG=-mappletvos-version-min=18.0
    MAKE_PLATFORM=tvos-arm64
    XCRUN_SDK=appletvos ;;
mac)
    # Mac Catalyst, riding the ios-arm64 Makefile case with the shim
    # below rewriting the platform flags to the macabi triple. Same
    # approach as tools/build-core.sh's mac case.
    SDK=$(xcrun -sdk macosx --show-sdk-path)
    MINVERSION_FLAG="-target arm64-apple-ios18.0-macabi"
    MAKE_PLATFORM=ios-arm64
    XCRUN_SDK=macosx ;;
*)
    echo "unknown platform: $PLATFORM (expected ios, tvos or mac)" >&2; exit 1 ;;
esac

# bsat_wrapper.c is hand-written, not part of the cloned repo, and lives
# in the original ios spike directory regardless of which platform is
# building; only the clone itself needs a separate directory per platform
# to avoid mixing iOS and tvOS .o files.
WRAPPER_SRC=spikes/BeetleSaturnStatic/bsat_wrapper.c
SPIKE=spikes/BeetleSaturnStatic
if [ "$PLATFORM" != ios ]; then
    SPIKE=spikes/BeetleSaturnStatic-${PLATFORM}
fi
SRC=$SPIKE/beetle-saturn-libretro
OUT=RommApp/RommApp/Native/Saturn
LIB=libbeetle_saturn_${PLATFORM}.a

if [ ! -d "$SRC" ]; then
    mkdir -p "$SPIKE"
    git clone --depth 1 https://github.com/libretro/beetle-saturn-libretro.git "$SRC"
fi

# -fno-common: an uninitialized non-static global compiles as a
# tentative-definition "common" symbol by default, and this build's own
# -exported_symbols_list step does not localize commons at all, so a name
# this core happens to share with another core silently shares one memory
# address instead of colliding at link time. Shimmed via PATH, absolute,
# not relative: `make -C` changes the process's own working directory
# before running any recipe, and a relative PATH entry stops resolving
# once that happens. See tools/build-core.sh's matching comment; this
# script predates that one and never got the same fix until it was found
# missing here entirely (0 commons had never been verified for Saturn).
WRAP="$(pwd)/$SPIKE/ccwrap"
mkdir -p "$WRAP"
real_cc=$(xcrun -sdk "$XCRUN_SDK" -find clang)
real_cxx=$(xcrun -sdk "$XCRUN_SDK" -find clang++)
if [ "$PLATFORM" = mac ]; then
    # The Catalyst rewrite on top of -fno-common: strip the Makefile's
    # iOS minimum-version and sysroot flags, substitute the macabi
    # target and the macOS SDK. See tools/build-core.sh's mac shim.
    for tool in cc clang; do
        printf '#!/bin/bash\nout=(); skip=0\nfor a in "$@"; do\n  if [[ $skip == 1 ]]; then skip=0; continue; fi\n  case "$a" in\n    -miphoneos-version-min=*) continue ;;\n    -isysroot) skip=1; continue ;;\n  esac\n  out+=("$a")\ndone\nexec "%s" -fno-common -target arm64-apple-ios18.0-macabi -isysroot "%s" "${out[@]}"\n' "$real_cc" "$SDK" > "$WRAP/$tool"
    done
    for tool in c++ clang++; do
        printf '#!/bin/bash\nout=(); skip=0\nfor a in "$@"; do\n  if [[ $skip == 1 ]]; then skip=0; continue; fi\n  case "$a" in\n    -miphoneos-version-min=*) continue ;;\n    -isysroot) skip=1; continue ;;\n  esac\n  out+=("$a")\ndone\nexec "%s" -fno-common -target arm64-apple-ios18.0-macabi -isysroot "%s" "${out[@]}"\n' "$real_cxx" "$SDK" > "$WRAP/$tool"
    done
else
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cc" > "$WRAP/cc"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cc" > "$WRAP/clang"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cxx" > "$WRAP/c++"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cxx" > "$WRAP/clang++"
fi
chmod +x "$WRAP"/*

PATH="$WRAP:$PATH" make -C "$SRC" platform=$MAKE_PLATFORM -j"$(sysctl -n hw.ncpu)"

DYLIB=$(find "$SRC" -maxdepth 1 -name '*.dylib' | head -1)
[ -n "$DYLIB" ] || { echo "no dylib produced" >&2; exit 1; }

# MINVERSION_FLAG unquoted on purpose: the mac value is two words.
cc -arch arm64 -isysroot "$SDK" $MINVERSION_FLAG -O2 \
    -I"$SRC" -c "$WRAPPER_SRC" -o "$SPIKE/bsat_wrapper.o"

nm -g "$DYLIB" 2>/dev/null \
    | awk '/ T _retro_/{print $NF}' | sed 's/^_retro_/_bsat_retro_/' | sort -u \
    > "$SPIKE/bsat_exports.txt"

find "$SRC" -name '*.o' > "$SPIKE/objects.txt"
ld -r -arch arm64 -syslibroot "$SDK" \
    "$SPIKE/bsat_wrapper.o" $(cat "$SPIKE/objects.txt") \
    -exported_symbols_list "$SPIKE/bsat_exports.txt" \
    -o "$SPIKE/beetle_saturn_combined.o"

mkdir -p "$OUT"
rm -f "$OUT/$LIB"
ar rcs "$OUT/$LIB" "$SPIKE/beetle_saturn_combined.o"
echo "Wrote $OUT/$LIB"
