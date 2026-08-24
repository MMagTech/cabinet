#!/bin/sh
# Builds RommApp/RommApp/Native/PPSSPP/libppsspp_$PLATFORM.a from the
# upstream PPSSPP sources. Usage: build-ppsspp.sh [ios|tvos]
#
# Same shape of output as build-flycast.sh: a single merged relocatable
# object whose only exported symbols are psp_retro_* forwarders
# (psp_wrapper.c), so PPSSPP's own retro_* names, its vendored
# libraries and its prebuilt ffmpeg cannot collide with any other
# core's. See build-beetle-saturn.sh's header for why the renaming has
# to happen in C: Apple's toolchain ships no object-file symbol
# renamer.
#
# PPSSPP builds with CMake and ships its own iOS toolchain file, which
# also knows tvOS (IOS_PLATFORM=TVOS): it sets USING_GLES2 and
# MOBILE_DEVICE, points the ffmpeg lookup at the prebuilt static libs
# the tree carries for each platform (ffmpeg/ios/universal and
# ffmpeg/tvos/arm64, both real arm64 archives, checked 2026-08-24),
# and IOS AND LIBRETRO is a combination upstream's CMakeLists handles
# by name. So unlike Flycast there is no masquerade here; this script
# just drives upstream's own supported configuration.
#
# No interpreter compile flag is needed the way Flycast needed
# TARGET_NO_REC: PPSSPP picks its CPU core at runtime from the
# ppsspp_cpu_core option, and "IR JIT" on a platform where
# SYSPROP_CAN_JIT is false resolves to the IR interpreter, the
# configuration the Mac lab benched 2026-08-24. NativeCoreOptions
# forces that option; the ARM64 JIT backend compiles in but is never
# asked to run.
#
# The prebuilt ffmpeg archives (avcodec, avformat, avutil, swresample,
# swscale; upstream links no avdevice) join the ld -r as archives, not
# swept objects: ld pulls only the members the core actually
# references, and everything it pulls disappears behind the exported
# symbols list like the rest of the merge.
set -e

cd "$(dirname "$0")/.."
PLATFORM=${1:-ios}
SPIKE=spikes/cores/ppsspp
SRC=$SPIKE/src
BUILD=$SPIKE/build-$PLATFORM
OUT=RommApp/RommApp/Native/PPSSPP
JOBS=$(sysctl -n hw.ncpu)

case "$PLATFORM" in
ios)
    SDK=$(xcrun -sdk iphoneos --show-sdk-path)
    MINVERSION_FLAG=-mios-version-min=13.0
    IOS_PLATFORM=OS
    FFMPEG_ARCH=ios/universal ;;
tvos)
    SDK=$(xcrun -sdk appletvos --show-sdk-path)
    MINVERSION_FLAG=-mappletvos-version-min=13.0
    IOS_PLATFORM=TVOS
    FFMPEG_ARCH=tvos/arm64 ;;
*)
    echo "unknown platform: $PLATFORM (expected ios or tvos)" >&2; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    mkdir -p "$SPIKE"
    git clone --recurse-submodules --depth 1 https://github.com/hrydgard/ppsspp.git "$SRC"
fi

cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$PWD/$SRC/cmake/Toolchains/ios.cmake" \
    -DIOS_PLATFORM=$IOS_PLATFORM \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBRETRO=ON \
    -DUSE_SYSTEM_FFMPEG=OFF \
    -DUSE_DISCORD=OFF \
    -DCMAKE_C_FLAGS=-fno-common \
    -DCMAKE_CXX_FLAGS=-fno-common

cmake --build "$BUILD" -j"$JOBS" --target ppsspp_libretro

cat > "$SPIKE/psp_wrapper.c" <<'EOF'
/* Prefix wrapper for PPSSPP. Apple's toolchain ships no object-file
 * symbol renamer, so the rename happens in C instead: these psp_*
 * functions are the only symbols the merged core object exports, and
 * the real retro_* definitions they call become private to it via
 * `ld -r -exported_symbols_list`. See tools/build-ppsspp.sh. */

#include <stddef.h>
#include <stdbool.h>
#include "libretro.h"

unsigned psp_retro_api_version(void) { return retro_api_version(); }
void psp_retro_get_system_info(struct retro_system_info *info) { retro_get_system_info(info); }
void psp_retro_get_system_av_info(struct retro_system_av_info *info) { retro_get_system_av_info(info); }
void psp_retro_set_environment(retro_environment_t cb) { retro_set_environment(cb); }
void psp_retro_set_video_refresh(retro_video_refresh_t cb) { retro_set_video_refresh(cb); }
void psp_retro_set_audio_sample(retro_audio_sample_t cb) { retro_set_audio_sample(cb); }
void psp_retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { retro_set_audio_sample_batch(cb); }
void psp_retro_set_input_poll(retro_input_poll_t cb) { retro_set_input_poll(cb); }
void psp_retro_set_input_state(retro_input_state_t cb) { retro_set_input_state(cb); }
void psp_retro_set_controller_port_device(unsigned port, unsigned device) { retro_set_controller_port_device(port, device); }
void psp_retro_init(void) { retro_init(); }
void psp_retro_deinit(void) { retro_deinit(); }
void psp_retro_reset(void) { retro_reset(); }
void psp_retro_run(void) { retro_run(); }
bool psp_retro_load_game(const struct retro_game_info *game) { return retro_load_game(game); }
bool psp_retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t num) { return retro_load_game_special(type, info, num); }
void psp_retro_unload_game(void) { retro_unload_game(); }
unsigned psp_retro_get_region(void) { return retro_get_region(); }
size_t psp_retro_serialize_size(void) { return retro_serialize_size(); }
bool psp_retro_serialize(void *data, size_t size) { return retro_serialize(data, size); }
bool psp_retro_unserialize(const void *data, size_t size) { return retro_unserialize(data, size); }
void psp_retro_cheat_reset(void) { retro_cheat_reset(); }
void psp_retro_cheat_set(unsigned index, bool enabled, const char *code) { retro_cheat_set(index, enabled, code); }
void *psp_retro_get_memory_data(unsigned id) { return retro_get_memory_data(id); }
size_t psp_retro_get_memory_size(unsigned id) { return retro_get_memory_size(id); }
EOF

cc -arch arm64 -isysroot "$SDK" $MINVERSION_FLAG -O2 \
    -I"$SRC/libretro/libretro-common/include" \
    -c "$SPIKE/psp_wrapper.c" -o "$SPIKE/psp_wrapper-$PLATFORM.o"

DYLIB=$(find "$BUILD" -name 'ppsspp_libretro.dylib' | head -1)
nm -g "$DYLIB" \
    | awk '/ T _retro_/{print $NF}' | sed 's/^_retro_/_psp_retro_/' | sort -u \
    > "$SPIKE/exports-$PLATFORM.txt"

# The merge mirrors the dylib's own link instead of sweeping every
# object in the build tree. A full sweep force-includes members the
# real link never loads, and PPSSPP's tree has several: objects
# referencing the x86 emitter on an arm64 build, ZIM screenshot
# saving, UI views, all of which the dylib link simply never pulls.
# So: the libretro target's own objects go in whole, and everything
# else joins as static archives, from which ld -r loads only the
# members that resolve a reference, exactly the semantics the shared
# library was linked with. That also settles the two vendored LZMA
# copies (ext/lzma-sdk and libchdr's deps/lzma-24.05) without a
# hand-written exclusion: whichever archive satisfies a symbol first
# wins, and the other copy's member is never pulled.
find "$BUILD/libretro" -name '*.o' > "$SPIKE/objects-$PLATFORM.txt"
find "$BUILD" -name '*.a' > "$SPIKE/archives-$PLATFORM.txt"
FFMPEG_LIBS="$SRC/ffmpeg/$FFMPEG_ARCH/lib"
ld -r -arch arm64 -syslibroot "$SDK" \
    "$SPIKE/psp_wrapper-$PLATFORM.o" $(cat "$SPIKE/objects-$PLATFORM.txt") \
    $(cat "$SPIKE/archives-$PLATFORM.txt") \
    "$FFMPEG_LIBS/libavcodec.a" "$FFMPEG_LIBS/libavformat.a" \
    "$FFMPEG_LIBS/libavutil.a" "$FFMPEG_LIBS/libswresample.a" \
    "$FFMPEG_LIBS/libswscale.a" \
    -exported_symbols_list "$SPIKE/exports-$PLATFORM.txt" \
    -o "$SPIKE/combined-$PLATFORM.o"

mkdir -p "$OUT"
LIB="libppsspp_$PLATFORM.a"
rm -f "$OUT/$LIB"
ar rcs "$OUT/$LIB" "$SPIKE/combined-$PLATFORM.o"
echo "Wrote $OUT/$LIB"
