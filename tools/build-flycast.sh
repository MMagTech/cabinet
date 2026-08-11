#!/bin/sh
# Builds RommApp/RommApp/Native/Flycast/libflycast_ios.a from the
# upstream Flycast sources.
#
# Same shape of output as build-beetle-saturn.sh: a single merged
# relocatable object whose only exported symbols are dc_retro_*
# forwarders (dc_wrapper.c), so Flycast's own retro_* names, and its
# bundled zlib/libchdr/libretro-common copies, cannot collide with any
# other core's. See build-beetle-saturn.sh's header for why that
# renaming has to happen in C at all: Apple's toolchain ships no
# object-file symbol renamer.
#
# Flycast builds with CMake, not a libretro Makefile, so it gets its
# own script rather than a case in build-core.sh's table. -fno-common
# and the interpreter-only/iOS defines go in as plain CMAKE_C_FLAGS /
# CMAKE_CXX_FLAGS, no ld PATH-shim trick needed the way the make-based
# builds require.
#
# -DTARGET_NO_REC forces the interpreter (no dynamic recompiler): this
# app's native cores run in the app process, which carries no JIT
# entitlement, the same constraint PCSX ReARMed and Beetle Saturn build
# under. -DUSE_VULKAN=ON is required for the CMake config to succeed
# even though this app only drives Flycast's GLES3 path; it costs
# nothing at runtime since GLES3 is what LibretroFrontend actually
# requests via RETRO_ENVIRONMENT_SET_HW_RENDER.
#
# libflycast-resources.a (cmrc-embedded fonts/shaders) is deliberately
# left out of the merge: the go/no-go build didn't link it and ran
# fine on real hardware, so whatever resources.cpp.o needs from it
# isn't on this app's call path.
set -e

cd "$(dirname "$0")/.."
SPIKE=spikes/cores/flycast
SRC=$SPIKE/src
BUILD=$SPIKE/build
OUT=RommApp/RommApp/Native/Flycast
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
JOBS=$(sysctl -n hw.ncpu)

if [ ! -d "$SRC" ]; then
    mkdir -p "$SPIKE"
    git clone --recurse-submodules --depth 1 https://github.com/flyinghead/flycast.git "$SRC"
fi

FLAGS="-fno-common -DTARGET_NO_REC -DIOS"
cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBRETRO=ON \
    -DUSE_OPENGL=ON \
    -DUSE_VULKAN=ON \
    -DCMAKE_C_FLAGS="$FLAGS" \
    -DCMAKE_CXX_FLAGS="$FLAGS"

cmake --build "$BUILD" -j"$JOBS"

cat > "$SPIKE/dc_wrapper.c" <<'EOF'
/* Prefix wrapper for Flycast. Apple's toolchain ships no object-file
 * symbol renamer, so the rename happens in C instead: these dc_*
 * functions are the only symbols the merged core object exports, and
 * the real retro_* definitions they call become private to it via
 * `ld -r -exported_symbols_list`. See tools/build-flycast.sh. */

#include <stddef.h>
#include <stdbool.h>
#include "libretro.h"

unsigned dc_retro_api_version(void) { return retro_api_version(); }
void dc_retro_get_system_info(struct retro_system_info *info) { retro_get_system_info(info); }
void dc_retro_get_system_av_info(struct retro_system_av_info *info) { retro_get_system_av_info(info); }
void dc_retro_set_environment(retro_environment_t cb) { retro_set_environment(cb); }
void dc_retro_set_video_refresh(retro_video_refresh_t cb) { retro_set_video_refresh(cb); }
void dc_retro_set_audio_sample(retro_audio_sample_t cb) { retro_set_audio_sample(cb); }
void dc_retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { retro_set_audio_sample_batch(cb); }
void dc_retro_set_input_poll(retro_input_poll_t cb) { retro_set_input_poll(cb); }
void dc_retro_set_input_state(retro_input_state_t cb) { retro_set_input_state(cb); }
void dc_retro_set_controller_port_device(unsigned port, unsigned device) { retro_set_controller_port_device(port, device); }
void dc_retro_init(void) { retro_init(); }
void dc_retro_deinit(void) { retro_deinit(); }
void dc_retro_reset(void) { retro_reset(); }
void dc_retro_run(void) { retro_run(); }
bool dc_retro_load_game(const struct retro_game_info *game) { return retro_load_game(game); }
bool dc_retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t num) { return retro_load_game_special(type, info, num); }
void dc_retro_unload_game(void) { retro_unload_game(); }
unsigned dc_retro_get_region(void) { return retro_get_region(); }
size_t dc_retro_serialize_size(void) { return retro_serialize_size(); }
bool dc_retro_serialize(void *data, size_t size) { return retro_serialize(data, size); }
bool dc_retro_unserialize(const void *data, size_t size) { return retro_unserialize(data, size); }
void dc_retro_cheat_reset(void) { retro_cheat_reset(); }
void dc_retro_cheat_set(unsigned index, bool enabled, const char *code) { retro_cheat_set(index, enabled, code); }
void *dc_retro_get_memory_data(unsigned id) { return retro_get_memory_data(id); }
size_t dc_retro_get_memory_size(unsigned id) { return retro_get_memory_size(id); }
EOF

cc -arch arm64 -isysroot "$SDK" -miphoneos-version-min=18.0 -O2 \
    -I"$SRC/core/deps/libretro-common/include" -I"$SRC/shell/libretro" -I"$SRC/core" \
    -c "$SPIKE/dc_wrapper.c" -o "$SPIKE/dc_wrapper.o"

nm -g "$BUILD/flycast_libretro.dylib" 2>/dev/null \
    | awk '/ T _retro_/{print $NF}' | sed 's/^_retro_/_dc_retro_/' | sort -u \
    > "$SPIKE/exports.txt"

# Swept from the whole build tree, not just flycast_libretro.dir:
# CMake pulls in its own static-lib subtargets (libzip, at last check)
# whose objects live in sibling directories, and a symbol only one of
# those provides (ZipSourceCallback, from libretro.cpp's zip-loading
# path) went undefined at final link when this only searched
# flycast_libretro.dir. libchdr's own deps/lzma-24.05 is excluded: it
# vendors a full second copy of the same LZMA SDK Flycast already
# builds under core/deps/lzma, same symbol names, so both in one
# ld -r collide. flycast_libretro.dir's own copy is the one everything
# actually links against.
find "$BUILD" -name '*.o' -not -path '*/lzma-24.05/*' > "$SPIKE/objects.txt"
ld -r -arch arm64 -syslibroot "$SDK" \
    "$SPIKE/dc_wrapper.o" $(cat "$SPIKE/objects.txt") \
    -exported_symbols_list "$SPIKE/exports.txt" \
    -o "$SPIKE/combined.o"

mkdir -p "$OUT"
rm -f "$OUT/libflycast_ios.a"
ar rcs "$OUT/libflycast_ios.a" "$SPIKE/combined.o"
echo "Wrote $OUT/libflycast_ios.a"
