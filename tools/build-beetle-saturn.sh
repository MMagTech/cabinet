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

# The wrapper is generated below rather than read from a hand-written
# file in spikes/, which was gitignored and therefore absent on a fresh
# clone of this repository. Same change, same reason, as the one in
# tools/build-core.sh. Only the core checkout needs a separate directory
# per platform, to avoid mixing iOS and tvOS .o files.
SPIKE=spikes/BeetleSaturnStatic
if [ "$PLATFORM" != ios ]; then
    SPIKE=spikes/BeetleSaturnStatic-${PLATFORM}
fi
SRC=$SPIKE/beetle-saturn-libretro
OUT=RommApp/RommApp/Native/Saturn
LIB=libbeetle_saturn_${PLATFORM}.a

# Pinned, same as tools/build-core.sh and for the same reason: a bare
# --depth 1 clone takes whatever upstream HEAD is that day, which is how
# this core came to ship one revision on iOS and another on macOS. The
# revision lives in docs/core-manifest.json.
MANIFEST=docs/core-manifest.json
PIN=$(python3 -c "
import json,sys
try:
    d = json.load(open('$MANIFEST'))['cores']
except Exception as e:
    sys.exit('cannot read $MANIFEST: %s' % e)
print(d['beetle_saturn'].get('pinned_commit') or '')
") || exit 1

if [ -z "$PIN" ]; then
    echo "no pinned_commit for beetle_saturn in $MANIFEST." >&2
    exit 1
fi

if [ ! -d "$SRC" ]; then
    mkdir -p "$SRC"
    git -C "$SRC" init -q
    git -C "$SRC" remote add origin https://github.com/libretro/beetle-saturn-libretro.git
    git -C "$SRC" fetch -q --depth 1 origin "$PIN"
    git -C "$SRC" checkout -q FETCH_HEAD
fi

HAVE=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)
if [ "$HAVE" != "$PIN" ]; then
    echo "beetle_saturn: $SRC is at $HAVE but the manifest pins $PIN." >&2
    echo "To rebuild at the pinned revision:  rm -rf $SRC  and run again." >&2
    echo "Check for local edits first: git -C $SRC status --short" >&2
    exit 1
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

# Quoted heredoc: the comment below contains backticks that an unquoted
# one would try to execute. The include path is the core's own copy of
# libretro.h, which is why it differs from build-core.sh's wrapper.
WRAPPER_SRC=$SPIKE/bsat_wrapper.c
cat > "$WRAPPER_SRC" <<'WRAPPER_EOF'
/* Prefix wrapper for Beetle Saturn, generated by
 * tools/build-beetle-saturn.sh. FBNeo already links under the standard
 * retro_* names, and Apple's toolchain ships no object-file symbol
 * renamer, so the rename happens in C instead: these bsat_* functions
 * are the only symbols the merged core object exports, and the real
 * retro_* definitions they call become private to it via
 * `ld -r -exported_symbols_list`. */

#include <stddef.h>
#include <stdbool.h>
#include "libretro-common/include/libretro.h"

unsigned bsat_retro_api_version(void) { return retro_api_version(); }
void bsat_retro_get_system_info(struct retro_system_info *info) { retro_get_system_info(info); }
void bsat_retro_get_system_av_info(struct retro_system_av_info *info) { retro_get_system_av_info(info); }
void bsat_retro_set_environment(retro_environment_t cb) { retro_set_environment(cb); }
void bsat_retro_set_video_refresh(retro_video_refresh_t cb) { retro_set_video_refresh(cb); }
void bsat_retro_set_audio_sample(retro_audio_sample_t cb) { retro_set_audio_sample(cb); }
void bsat_retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { retro_set_audio_sample_batch(cb); }
void bsat_retro_set_input_poll(retro_input_poll_t cb) { retro_set_input_poll(cb); }
void bsat_retro_set_input_state(retro_input_state_t cb) { retro_set_input_state(cb); }
void bsat_retro_set_controller_port_device(unsigned port, unsigned device) { retro_set_controller_port_device(port, device); }
void bsat_retro_init(void) { retro_init(); }
void bsat_retro_deinit(void) { retro_deinit(); }
void bsat_retro_reset(void) { retro_reset(); }
void bsat_retro_run(void) { retro_run(); }
bool bsat_retro_load_game(const struct retro_game_info *game) { return retro_load_game(game); }
bool bsat_retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t num) { return retro_load_game_special(type, info, num); }
void bsat_retro_unload_game(void) { retro_unload_game(); }
unsigned bsat_retro_get_region(void) { return retro_get_region(); }
size_t bsat_retro_serialize_size(void) { return retro_serialize_size(); }
bool bsat_retro_serialize(void *data, size_t size) { return retro_serialize(data, size); }
bool bsat_retro_unserialize(const void *data, size_t size) { return retro_unserialize(data, size); }
void bsat_retro_cheat_reset(void) { retro_cheat_reset(); }
void bsat_retro_cheat_set(unsigned index, bool enabled, const char *code) { retro_cheat_set(index, enabled, code); }
void *bsat_retro_get_memory_data(unsigned id) { return retro_get_memory_data(id); }
size_t bsat_retro_get_memory_size(unsigned id) { return retro_get_memory_size(id); }
WRAPPER_EOF

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
