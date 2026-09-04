#!/bin/sh
# Builds RommApp/RommApp/Native/Mupen64Plus/libmupen64plus_$PLATFORM.a from
# the upstream mupen64plus-libretro-nx sources. Usage: build-n64.sh [ios|tvos]
# See roadmap-n64-native-attempt (2026-08-08, reverted) for why an earlier
# attempt at this exists and failed: it forced angrylion (software RDP) plus
# a bespoke interpreter flag and crashed inside the core's own plugin
# registration. This build uses upstream's own real ios-arm64/tvos-arm64
# platform targets instead of inventing flags, and lets GLideN64 (the
# default RDP plugin already) drive hardware rendering through a real GLES3
# context. That was the real unknown the 2026-08-11 go/no-go answered:
# GLideN64 has a genuine unified GL/GLES3 codepath with no desktop-only
# features, and despite its per-GPU workaround table having no
# Apple/PowerVR-successor entries at all, it renders correctly on Apple's
# own GLES3 driver, confirmed on real hardware. Graduated to a real native
# platform the same week.
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
# instead of a build-core.sh table entry: both ios-arm64 and tvos-arm64
# platform targets already force everything this spike needs (WITH_DYNAREC
# empty, no dynamic recompiler; GLES3=1 FORCE_GLES3=1, the GLES3
# hardware-render path), so there is no case-table worth of per-core flags
# to add, just one platform string. Interpreter choice at the CPU-core
# level is a runtime core option (mupen64plus-cpucore), forced to
# pure_interpreter below via LibretroFrontend's setCoreOptions, the same
# no-JIT exception Saturn, PS1 and Dreamcast already proved out: this app's
# cores run in the main app process, which carries no JIT entitlement.
set -e

cd "$(dirname "$0")/.."
PLATFORM=${1:-ios}
SPIKE=spikes/cores/mupen64plus
# A separate clone per platform, not a shared $SPIKE/src: this Makefile
# builds .o files in place alongside the source rather than into a
# separate build directory (unlike build-flycast.sh's CMake tree, which
# isolates by BUILD dir automatically), so a shared checkout would mix
# iOS and tvOS object files across a second platform's build the same
# way build-beetle-saturn.sh's own header warns against.
SRC=$SPIKE/src-$PLATFORM
OUT=RommApp/RommApp/Native/Mupen64Plus
JOBS=$(sysctl -n hw.ncpu)

case "$PLATFORM" in
ios)
    SDK=$(xcrun -sdk iphoneos --show-sdk-path)
    XCRUN_SDK=iphoneos
    MINVERSION_FLAG=-miphoneos-version-min=18.0
    MAKE_PLATFORM=ios-arm64 ;;
tvos)
    SDK=$(xcrun -sdk appletvos --show-sdk-path)
    XCRUN_SDK=appletvos
    MINVERSION_FLAG=-mappletvos-version-min=18.0
    MAKE_PLATFORM=tvos-arm64 ;;
mac)
    # Mac Catalyst, riding the ios-arm64 Makefile case (GLES3=1,
    # FORCE_GLES3=1, no dynarec) with the shim below rewriting the
    # platform flags to the macabi triple. GLES3 headers come from the
    # vendored ANGLE include tree: the macOS SDK ships none.
    SDK=$(xcrun -sdk macosx --show-sdk-path)
    XCRUN_SDK=macosx
    MINVERSION_FLAG="-target arm64-apple-ios18.0-macabi"
    MAKE_PLATFORM=ios-arm64 ;;
*)
    echo "unknown platform: $PLATFORM (expected ios, tvos or mac)" >&2; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
    mkdir -p "$SPIKE"
    git clone --depth 1 --recurse-submodules --shallow-submodules \
        https://github.com/libretro/mupen64plus-libretro-nx "$SRC"
fi

# Same -fno-common wrapper as build-core.sh, and the same reasoning:
# this core's own Makefile bakes -arch/-isysroot into CC directly for
# platform=$MAKE_PLATFORM, so a CC= override on the make command line would
# silently drop the target rather than add to it. Shimming the real
# compiler binaries on PATH instead injects -fno-common into every
# invocation while leaving the Makefile's own CC string alone.
#
# -fno-common goes both before AND after "$@": this Makefile's own
# CPUOPTS explicitly adds -fcommon (Makefile line ~665, unconditional,
# not platform-gated), and -fcommon/-fno-common resolve last-flag-wins on
# the command line. Appending after "$@" too, not just before it, is what
# actually wins regardless of where the Makefile's own -fcommon lands in
# the final invocation, keeping this core's tentative-definition globals
# hidden rather than exported the same way the fbneo/gpgx "snd" collision
# was found and fixed.
#
# -D__MATH_H__: the vendored libpng copy under custom/dependencies/libpng
# guards its fp.h-vs-math.h choice with TARGET_OS_MAC, which is true on
# every Apple platform including iOS and tvOS, but Apple has never shipped
# fp.h (that was a classic Mac OS Universal Headers thing). The header
# meant this as "if math.h has not already been included, prefer the more
# precise fp.h", but Apple's own math.h include guard is _MATH_H_, not
# __MATH_H__, so the check can never see it and always takes the fp.h
# branch. Defining __MATH_H__ ourselves is the same workaround other
# Apple ports of this exact vendored libpng use: it just forces the
# math.h branch, which is what every other platform's libc gets anyway.
#
# -Dfdopen=fdopen: the vendored zlib's zutil.h has the same TARGET_OS_MAC
# problem in a different shape. Under `#ifndef fdopen` it #defines fdopen
# to the literal token NULL, meaning "this platform has no fdopen", true
# for classic Mac OS but not for iOS/tvOS, which both have a real one.
# That bad macro then corrupts the following #include <stdio.h>'s own
# fdopen prototype line (its expansion literally becomes `NULL(int, const
# char*) ...`, a syntax error). Predefining fdopen as itself satisfies
# the #ifndef guard so the bad redefinition never happens, and every real
# call site still expands to a plain call to the real libc fdopen.
WRAP="$(pwd)/$SPIKE/ccwrap-$PLATFORM"
mkdir -p "$WRAP"
real_cc=$(xcrun -sdk "$XCRUN_SDK" -find clang)
real_cxx=$(xcrun -sdk "$XCRUN_SDK" -find clang++)
#
# -D__MATH_H__ goes to the C compilers only, never to C++: libc++'s own
# <cmath> includes the same math.h and re-declares fpclassify's helpers
# in terms of FP_NAN/FP_INFINITE/FP_NORMAL/FP_SUBNORMAL/FP_ZERO, all of
# which live behind that very include guard, so defining it hides them
# and every C++ file that touches <cmath> fails with "use of undeclared
# identifier 'FP_NAN'". GLideN64 is C++ and includes <cmath> widely,
# which is where this surfaced (2026-08-11, first tvOS build); the same
# breakage was latent in the iOS wrapper too and simply never got hit,
# since only the C-side vendored libpng ever needed the define.
# To debug a crash in this core, add -g here the way build-flycast.sh's
# header describes, so a crash report resolves to source lines via atos.
# Note that -fno-omit-frame-pointer does NOT work from this position: this
# Makefile's own CPUOPTS appends -fomit-frame-pointer unconditionally, and
# these resolve last-flag-wins, exactly like the -fcommon case above. It
# has to go after "$@" to take effect. Chasing missing stack frames
# without noticing that cost a build cycle on 2026-08-16.
if [ "$PLATFORM" = mac ]; then
    # The Catalyst rewrite on top of everything the normal shim does:
    # strip the Makefile's iOS min-version and sysroot flags, keep the
    # per-compiler defines exactly as below, substitute the macabi
    # triple, the macOS SDK and the vendored GLES headers. See
    # tools/build-core.sh's mac shim for the pattern.
    ANGLE_INC="$(pwd)/RommApp/Vendor/ANGLE/include"
    GLES_COMPAT="$(pwd)/tools/mac-support/gles-compat"
    ANGLE_MAC="$(pwd)/RommApp/Vendor/ANGLE/mac"
    for tool in cc clang c++ clang++; do
        case "$tool" in
        cc|clang) REAL="$real_cc"; EXTRA_DEFS="-D__MATH_H__ -Dfdopen=fdopen" ;;
        *) REAL="$real_cxx"; EXTRA_DEFS="-Dfdopen=fdopen" ;;
        esac
        cat > "$WRAP/$tool" <<SHIM
#!/bin/bash
# Catalyst rewrite: strip the ios-arm64 case's platform flags, swap
# Apple's OpenGLES framework for the vendored ANGLE one, keep the
# per-compiler defines. Generated by tools/build-n64.sh's mac case.
out=(); skip=0; fw=0
for a in "\$@"; do
  if [[ \$skip == 1 ]]; then skip=0; continue; fi
  if [[ \$fw == 1 ]]; then
    fw=0
    if [[ \$a == OpenGLES ]]; then continue; fi
    out+=(-framework "\$a"); continue
  fi
  case "\$a" in
    -miphoneos-version-min=*) continue ;;
    -isysroot) skip=1; continue ;;
    -framework) fw=1; continue ;;
  esac
  out+=("\$a")
done
exec "$REAL" -fno-common $EXTRA_DEFS -target arm64-apple-ios18.0-macabi -isysroot "$SDK" -I"$ANGLE_INC" -I"$GLES_COMPAT" -F"$ANGLE_MAC" -framework libGLESv2 -framework libEGL "\${out[@]}" -fno-common
SHIM
    done
else
    printf '#!/bin/sh\nexec "%s" -fno-common -D__MATH_H__ -Dfdopen=fdopen "$@" -fno-common\n' "$real_cc" > "$WRAP/cc"
    printf '#!/bin/sh\nexec "%s" -fno-common -D__MATH_H__ -Dfdopen=fdopen "$@" -fno-common\n' "$real_cc" > "$WRAP/clang"
    printf '#!/bin/sh\nexec "%s" -fno-common -Dfdopen=fdopen "$@" -fno-common\n' "$real_cxx" > "$WRAP/c++"
    printf '#!/bin/sh\nexec "%s" -fno-common -Dfdopen=fdopen "$@" -fno-common\n' "$real_cxx" > "$WRAP/clang++"
fi
chmod +x "$WRAP"/*

PATH="$WRAP:$PATH" IOSSDK="$SDK" \
    make -C "$SRC" -f Makefile platform=$MAKE_PLATFORM -j"$JOBS"

DYLIB=$(find "$SRC" -maxdepth 1 -name '*.dylib' | head -1)
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

cc -arch arm64 -isysroot "$SDK" $MINVERSION_FLAG -O2 \
    -I"$SRC/libretro-common/include" \
    -c "$SPIKE/n64_wrapper.c" -o "$SPIKE/n64_wrapper-$PLATFORM.o"

nm -g "$DYLIB" 2>/dev/null \
    | awk '/ T _retro_/{print $NF}' | sed 's/^_retro_/_n64_retro_/' | sort -u \
    > "$SPIKE/exports-$PLATFORM.txt"

find "$SRC" -name '*.o' > "$SPIKE/objects-$PLATFORM.txt"
ld -r -arch arm64 -syslibroot "$SDK" \
    "$SPIKE/n64_wrapper-$PLATFORM.o" $(cat "$SPIKE/objects-$PLATFORM.txt") \
    -exported_symbols_list "$SPIKE/exports-$PLATFORM.txt" \
    -o "$SPIKE/combined-$PLATFORM.o"

mkdir -p "$OUT"
LIB="libmupen64plus_$PLATFORM.a"
rm -f "$OUT/$LIB"
ar rcs "$OUT/$LIB" "$SPIKE/combined-$PLATFORM.o"
echo "Wrote $OUT/$LIB"
