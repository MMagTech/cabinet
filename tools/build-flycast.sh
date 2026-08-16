#!/bin/sh
# Builds RommApp/RommApp/Native/Flycast/libflycast_$PLATFORM.a from the
# upstream Flycast sources. Usage: build-flycast.sh [ios|tvos]
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
# -DIOS stays on for tvOS too: it only gates Flycast's own platform/
# shell layer (windowing, input), none of which this app reaches since
# it builds LIBRETRO=ON, core only, driven entirely through the
# libretro API and this app's own LibretroFrontend.mm GL context, the
# same way the iOS build already works without touching Flycast's shell
# at all.
#
# libflycast-resources.a (cmrc-embedded fonts/shaders) is deliberately
# left out of the merge: the go/no-go build didn't link it and ran
# fine on real hardware, so whatever resources.cpp.o needs from it
# isn't on this app's call path.
set -e

cd "$(dirname "$0")/.."
PLATFORM=${1:-ios}
SPIKE=spikes/cores/flycast
SRC=$SPIKE/src
BUILD=$SPIKE/build-$PLATFORM
OUT=RommApp/RommApp/Native/Flycast
JOBS=$(sysctl -n hw.ncpu)

case "$PLATFORM" in
ios)
    SDK=$(xcrun -sdk iphoneos --show-sdk-path)
    OSX_SYSROOT=iphoneos
    MINVERSION_FLAG=-miphoneos-version-min=18.0
    DEPLOYMENT_TARGET=18.0
    SYSTEM_NAME=iOS ;;
tvos)
    SDK=$(xcrun -sdk appletvos --show-sdk-path)
    OSX_SYSROOT=appletvos
    MINVERSION_FLAG=-mappletvos-version-min=18.0
    DEPLOYMENT_TARGET=18.0
    SYSTEM_NAME=tvOS ;;
*)
    echo "unknown platform: $PLATFORM (expected ios or tvos)" >&2; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    mkdir -p "$SPIKE"
    git clone --recurse-submodules --depth 1 https://github.com/flyinghead/flycast.git "$SRC"
fi

# Patch upstream's interpreter cycle ratio, same in-build-script patching
# precedent as build-core.sh's Beetle PCE zlib fix. Upstream charges every
# interpreted instruction 8 cycles ("SH4 underclock factor when using the
# interpreter so that it's somewhat usable"), which hands games an
# effective 25MHz SH4: enough for light scenes, and the direct cause of
# heavy scenes slowing down inside the emulated machine, identically on
# any host hardware (issue #6's 20fps, diagnosed 2026-08-16 with the
# frame trace). Charging 2 instead gives an effective 100MHz. Both
# values around it were measured on device 2026-08-16 and rejected: 8 is
# the 20fps heavy-scene slowdown, and 1 (the authentic 200MHz) saturates
# even an iPhone Air's interpreter, audio ratio flooring at 0.60 with
# audible dropouts. Per-platform tuning below 100MHz happens at runtime
# instead, via the reicast_sh4clock option NativeCoreOptions forces per
# platform, so both platforms share one core build. The audio governor
# turns any remaining shortfall into graceful slowdown rather than
# static, measurable as the trace's audio ratio dropping below 1.0.
# Idempotent; harmless if upstream renames the constant, the build then
# just carries upstream's value. The sed targets whatever value the tree
# currently holds, so it matches 8 (a fresh clone) or a previous run's.
CPU_RATIO=2
sed -i '' "s/static constexpr int CPU_RATIO = [0-9]*;/static constexpr int CPU_RATIO = $CPU_RATIO;/" \
    "$SRC/core/hw/sh4/sh4_interpreter.h"

# Second upstream patch: let a fresh retro_load_game start the emulator.
#
# Flycast only ever calls emu.start() when its `first_run` flag is set,
# and that flag is set only by retro_init and retro_deinit. That assumes
# a frontend deinitializes the core between games, which Cabinet cannot
# do here: Flycast's own retro_deinit calls addrspace::release() without
# emu.term() on Apple, leaving the Emulator in state Init with its
# address space gone, so the next retro_init early-returns out of
# Emulator::init(), never re-runs mem_Init(), and the first dc_reset
# writes to unmapped memory (SIGSEGV, refused by Flycast's own fault
# handler, die("segfault")). That was the "quit a Dreamcast game and the
# next one closes the app" crash, pinned to emulator.cpp:594 by a
# debug-info build 2026-08-16. LibretroFrontend.mm therefore never
# deinitializes this core, which left the opposite symptom: the second
# game loaded but never started, stayed in state Loaded, rendered
# nothing, and showed a black screen.
#
# Setting the flag when a game unloads says exactly what is true: the
# next game to load has not been started yet. Anchored on the two-line
# opening of retro_unload_game, which is unique in the file, and made a
# no-op if the patch is already present, so re-running this script is
# safe. If upstream ever fixes retro_deinit, this stays harmless.
perl -0pi -e '
    s/(\temu\.unloadGame\(\);\n)(\tdreampotato::term\(\);)/$1\tfirst_run = true;\n$2/
    unless /first_run = true;\n\tdreampotato::term/;
' "$SRC/shell/libretro/libretro.cpp"
grep -q 'first_run = true;' "$SRC/shell/libretro/libretro.cpp" \
    && grep -A 2 'emu.unloadGame();' "$SRC/shell/libretro/libretro.cpp" | grep -q 'first_run = true;' \
    || { echo "first_run patch did not apply; upstream shape changed" >&2; exit 1; }

FLAGS="-fno-common -DTARGET_NO_REC -DIOS"

# tvOS masquerades as iOS to Flycast's own build, via -DIOS=ON below.
# Flycast keys every GLES decision off CMake's `IOS` variable, which CMake
# itself only sets for CMAKE_SYSTEM_NAME=iOS, never tvOS. Without it the
# tvOS build silently falls through to the desktop-GL branch: GLES/GLES3/
# HAVE_OPENGLES/HAVE_OPENGLES3 all stay undefined, libretro-common's
# glsym.h then includes glsym_gl.h instead of glsym_es3.h, and the build
# dies in a wall of desktop-GL typedef redefinitions. Same shape of bug
# as the GLSM-hardcodes-GLES2 one the Dreamcast go/no-go turned up, just
# in the opposite direction.
#
# TARGET_IPHONE comes along with it, and is wanted for its own reason:
# core/types.h guards its JITWriteProtect helper with
# `#ifndef TARGET_IPHONE`, and the fallback branch calls
# pthread_jit_write_protect_np, which is flatly unavailable on tvOS (hard
# compile error). Safe either way: this is an interpreter-only build
# (-DTARGET_NO_REC), so nothing ever asks to make JIT pages writable.
IOS_FLAG=OFF
[ "$PLATFORM" = tvos ] && IOS_FLAG=ON
cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=$SYSTEM_NAME \
    -DCMAKE_OSX_SYSROOT=$OSX_SYSROOT \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBRETRO=ON \
    -DUSE_OPENGL=ON \
    -DUSE_VULKAN=ON \
    ${IOS_FLAG:+-DIOS=$IOS_FLAG} \
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

cc -arch arm64 -isysroot "$SDK" $MINVERSION_FLAG -O2 \
    -I"$SRC/core/deps/libretro-common/include" -I"$SRC/shell/libretro" -I"$SRC/core" \
    -c "$SPIKE/dc_wrapper.c" -o "$SPIKE/dc_wrapper-$PLATFORM.o"

nm -g "$BUILD/flycast_libretro.dylib" 2>/dev/null \
    | awk '/ T _retro_/{print $NF}' | sed 's/^_retro_/_dc_retro_/' | sort -u \
    > "$SPIKE/exports-$PLATFORM.txt"

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
find "$BUILD" -name '*.o' -not -path '*/lzma-24.05/*' > "$SPIKE/objects-$PLATFORM.txt"
ld -r -arch arm64 -syslibroot "$SDK" \
    "$SPIKE/dc_wrapper-$PLATFORM.o" $(cat "$SPIKE/objects-$PLATFORM.txt") \
    -exported_symbols_list "$SPIKE/exports-$PLATFORM.txt" \
    -o "$SPIKE/combined-$PLATFORM.o"

mkdir -p "$OUT"
LIB="libflycast_$PLATFORM.a"
rm -f "$OUT/$LIB"
ar rcs "$OUT/$LIB" "$SPIKE/combined-$PLATFORM.o"
echo "Wrote $OUT/$LIB"
