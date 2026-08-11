#!/bin/sh
# Builds RommApp/RommApp/Native/Mupen64Plus/libmupen64plus_ios.a from the
# upstream mupen64plus-libretro-nx sources. See roadmap-n64-native-attempt
# (2026-08-08, reverted) for why an earlier attempt at this exists and
# failed: it forced angrylion (software RDP) plus a bespoke interpreter
# flag and crashed inside the core's own plugin registration. This build
# uses upstream's own real ios-arm64 platform target instead of inventing
# flags, and lets GLideN64 (the default RDP plugin already) drive
# hardware rendering through a real GLES3 context. That was the real
# unknown the 2026-08-11 go/no-go answered: GLideN64 has a genuine
# unified GL/GLES3 codepath with no desktop-only features, and despite
# its per-GPU workaround table having no Apple/PowerVR-successor entries
# at all, it renders correctly on Apple's own GLES3 driver, confirmed on
# real hardware. Graduated to a real native platform the same week.
#
# Same shape of output as build-flycast.sh: a single merged relocatable
# object whose only exported symbols are n64_retro_* forwarders
# (n64_wrapper.c), so this core's own retro_* names and its bundled
# zlib/libretro-common copies cannot collide with any other statically
# linked core's. See build-flycast.sh's header for why that renaming has
# to happen in C at all: Apple's toolchain ships no object-file symbol
# renamer.
#
# Makefile-based (libretro-standard Makefile, not CMake), so this uses
# build-core.sh's ccwrap/-fno-common PATH-shim pattern rather than
# build-flycast.sh's CMAKE_C_FLAGS one, but stays a standalone script
# instead of a build-core.sh table entry: the ios-arm64 platform target
# already forces everything this spike needs (WITH_DYNAREC empty, no
# dynamic recompiler; GLES3=1 FORCE_GLES3=1, the GLES3 hardware-render
# path), so there is no case-table worth of per-core flags to add, just
# one platform string. Interpreter choice at the CPU-core level is a
# runtime core option (mupen64plus-cpucore), forced to pure_interpreter
# below via LibretroFrontend's setCoreOptions, the same no-JIT exception
# Saturn, PS1 and Dreamcast already proved out: this app's cores run in
# the main app process, which carries no JIT entitlement.
set -e

cd "$(dirname "$0")/.."
SPIKE=spikes/cores/mupen64plus
SRC=$SPIKE/src
OUT=RommApp/RommApp/Native/Mupen64Plus
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
JOBS=$(sysctl -n hw.ncpu)

if [ ! -d "$SRC" ]; then
    mkdir -p "$SPIKE"
    git clone --depth 1 --recurse-submodules --shallow-submodules \
        https://github.com/libretro/mupen64plus-libretro-nx "$SRC"
fi

# Same -fno-common wrapper as build-core.sh, and the same reasoning:
# this core's own Makefile bakes -arch/-isysroot into CC directly for
# platform=ios-arm64, so a CC= override on the make command line would
# silently drop the iOS target rather than add to it. Shimming the real
# compiler binaries on PATH instead injects -fno-common into every
# invocation while leaving the Makefile's own CC string alone.
WRAP="$(pwd)/$SPIKE/ccwrap"
mkdir -p "$WRAP"
real_cc=$(xcrun -sdk iphoneos -find clang)
real_cxx=$(xcrun -sdk iphoneos -find clang++)
# -D__MATH_H__: the vendored libpng copy under custom/dependencies/libpng
# guards its fp.h-vs-math.h choice with TARGET_OS_MAC, which is true on
# every Apple platform including iOS, but Apple has never shipped fp.h
# (that was a classic Mac OS Universal Headers thing). The header meant
# this as "if math.h has not already been included, prefer the more
# precise fp.h", but Apple's own math.h include guard is _MATH_H_, not
# __MATH_H__, so the check can never see it and always takes the fp.h
# branch. Defining __MATH_H__ ourselves is the same workaround other
# Apple ports of this exact vendored libpng use: it just forces the
# math.h branch, which is what every other platform's libc gets anyway.
#
# -Dfdopen=fdopen: the vendored zlib's zutil.h has the same TARGET_OS_MAC
# problem in a different shape. Under `#ifndef fdopen` it #defines fdopen
# to the literal token NULL, meaning "this platform has no fdopen", true
# for classic Mac OS but not for iOS, which has a real one. That bad
# macro then corrupts the following #include <stdio.h>'s own fdopen
# prototype line (its expansion literally becomes `NULL(int, const
# char*) ...`, a syntax error). Predefining fdopen as itself satisfies
# the #ifndef guard so the bad redefinition never happens, and every
# real call site still expands to a plain call to the real libc fdopen.
printf '#!/bin/sh\nexec "%s" -fno-common -D__MATH_H__ -Dfdopen=fdopen "$@"\n' "$real_cc" > "$WRAP/cc"
printf '#!/bin/sh\nexec "%s" -fno-common -D__MATH_H__ -Dfdopen=fdopen "$@"\n' "$real_cc" > "$WRAP/clang"
printf '#!/bin/sh\nexec "%s" -fno-common -D__MATH_H__ -Dfdopen=fdopen "$@"\n' "$real_cxx" > "$WRAP/c++"
printf '#!/bin/sh\nexec "%s" -fno-common -D__MATH_H__ -Dfdopen=fdopen "$@"\n' "$real_cxx" > "$WRAP/clang++"
chmod +x "$WRAP"/*

PATH="$WRAP:$PATH" IOSSDK="$SDK" \
    make -C "$SRC" -f Makefile platform=ios-arm64 -j"$JOBS"

DYLIB=$(find "$SRC" -maxdepth 1 -name '*_ios.dylib')
[ -n "$DYLIB" ] || { echo "no dylib produced for mupen64plus" >&2; exit 1; }

cat > "$SPIKE/n64_wrapper.c" <<'EOF'
/* Prefix wrapper for mupen64plus-libretro-nx. Apple's toolchain ships no
 * object-file symbol renamer, so the rename happens in C instead: these
 * n64_* functions are the only symbols the merged core object exports,
 * and the real retro_* definitions they call become private to it via
 * `ld -r -exported_symbols_list`. See tools/build-n64.sh. */

#include <stddef.h>
#include <stdbool.h>
#include "libretro.h"

unsigned n64_retro_api_version(void) { return retro_api_version(); }
void n64_retro_get_system_info(struct retro_system_info *info) { retro_get_system_info(info); }
void n64_retro_get_system_av_info(struct retro_system_av_info *info) { retro_get_system_av_info(info); }
void n64_retro_set_environment(retro_environment_t cb) { retro_set_environment(cb); }
void n64_retro_set_video_refresh(retro_video_refresh_t cb) { retro_set_video_refresh(cb); }
void n64_retro_set_audio_sample(retro_audio_sample_t cb) { retro_set_audio_sample(cb); }
void n64_retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { retro_set_audio_sample_batch(cb); }
void n64_retro_set_input_poll(retro_input_poll_t cb) { retro_set_input_poll(cb); }
void n64_retro_set_input_state(retro_input_state_t cb) { retro_set_input_state(cb); }
void n64_retro_set_controller_port_device(unsigned port, unsigned device) { retro_set_controller_port_device(port, device); }
void n64_retro_init(void) { retro_init(); }
void n64_retro_deinit(void) { retro_deinit(); }
void n64_retro_reset(void) { retro_reset(); }
void n64_retro_run(void) { retro_run(); }
bool n64_retro_load_game(const struct retro_game_info *game) { return retro_load_game(game); }
bool n64_retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t num) { return retro_load_game_special(type, info, num); }
void n64_retro_unload_game(void) { retro_unload_game(); }
unsigned n64_retro_get_region(void) { return retro_get_region(); }
size_t n64_retro_serialize_size(void) { return retro_serialize_size(); }
bool n64_retro_serialize(void *data, size_t size) { return retro_serialize(data, size); }
bool n64_retro_unserialize(const void *data, size_t size) { return retro_unserialize(data, size); }
void n64_retro_cheat_reset(void) { retro_cheat_reset(); }
void n64_retro_cheat_set(unsigned index, bool enabled, const char *code) { retro_cheat_set(index, enabled, code); }
void *n64_retro_get_memory_data(unsigned id) { return retro_get_memory_data(id); }
size_t n64_retro_get_memory_size(unsigned id) { return retro_get_memory_size(id); }
EOF

cc -arch arm64 -isysroot "$SDK" -miphoneos-version-min=18.0 -O2 \
    -I"$SRC/libretro-common/include" \
    -c "$SPIKE/n64_wrapper.c" -o "$SPIKE/n64_wrapper.o"

nm -g "$DYLIB" 2>/dev/null \
    | awk '/ T _retro_/{print $NF}' | sed 's/^_retro_/_n64_retro_/' | sort -u \
    > "$SPIKE/exports.txt"

find "$SRC" -name '*.o' > "$SPIKE/objects.txt"
ld -r -arch arm64 -syslibroot "$SDK" \
    "$SPIKE/n64_wrapper.o" $(cat "$SPIKE/objects.txt") \
    -exported_symbols_list "$SPIKE/exports.txt" \
    -o "$SPIKE/combined.o"

mkdir -p "$OUT"
rm -f "$OUT/libmupen64plus_ios.a"
ar rcs "$OUT/libmupen64plus_ios.a" "$SPIKE/combined.o"
echo "Wrote $OUT/libmupen64plus_ios.a"
