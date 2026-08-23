#!/bin/sh
# Generic native core builder, the batch generalisation of
# build-beetle-saturn.sh. Same shape of output for every core: a single
# merged relocatable object whose only exported symbols are
# <prefix>_retro_* forwarders, so any number of cores can link into one
# binary without their retro_* names (or bundled zlib and friends)
# colliding. Usage: tools/build-core.sh <core-name> [ios|tvos]
#
# The platform argument defaults to ios. tvos is opt-in per core: it only
# works for a core whose own Makefile already has a tvos-arm64 (or
# equivalent) platform case, checked directly rather than assumed. As of
# this comment only pcsx_rearmed has been confirmed to have one; treat
# every other core's tvOS support as unverified until checked the same way.
set -e

cd "$(dirname "$0")/.."
NAME=$1
PLATFORM=${2:-ios}
JOBS=$(sysctl -n hw.ncpu)

case "$PLATFORM" in
ios)
    SDK=$(xcrun -sdk iphoneos --show-sdk-path)
    MINVERSION_FLAG=-miphoneos-version-min=18.0
    MAKE_PLATFORM=ios-arm64 ;;
tvos)
    SDK=$(xcrun -sdk appletvos --show-sdk-path)
    MINVERSION_FLAG=-mappletvos-version-min=18.0
    MAKE_PLATFORM=tvos-arm64 ;;
*)
    echo "unknown platform: $PLATFORM (expected ios or tvos)" >&2; exit 1 ;;
esac

case "$NAME" in
gambatte)
    PREFIX=gmb; REPO=https://github.com/libretro/gambatte-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=Gambatte; LIB=libgambatte_ios.a ;;
mgba)
    PREFIX=gba; REPO=https://github.com/libretro/mgba.git
    MAKEDIR=.; MAKEFILE=cmake; OUT=MGBA; LIB=libmgba_ios.a ;;
genesis_plus_gx)
    PREFIX=gpgx; REPO=https://github.com/libretro/Genesis-Plus-GX.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=GenesisPlusGX; LIB=libgenesis_plus_gx_ios.a ;;
beetle_pce_fast)
    PREFIX=pce; REPO=https://github.com/libretro/beetle-pce-fast-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=BeetlePCEFast; LIB=libbeetle_pce_fast_ios.a ;;
snes9x)
    PREFIX=s9x; REPO=https://github.com/libretro/snes9x.git
    MAKEDIR=libretro; MAKEFILE=Makefile; OUT=Snes9x; LIB=libsnes9x_ios.a ;;
fceumm)
    PREFIX=fcm; REPO=https://github.com/libretro/libretro-fceumm.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=FCEUmm; LIB=libfceumm_ios.a ;;
beetle_ngp)
    PREFIX=ngp; REPO=https://github.com/libretro/beetle-ngp-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=BeetleNGP; LIB=libbeetle_ngp_ios.a ;;
prosystem)
    PREFIX=a78; REPO=https://github.com/libretro/prosystem-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=ProSystem; LIB=libprosystem_ios.a ;;
picodrive)
    PREFIX=pico; REPO=https://github.com/libretro/picodrive.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=PicoDrive; LIB=libpicodrive_ios.a ;;
mame2003_plus)
    # The arcade core for the boards FinalBurn Neo does not cover: the
    # early-80s Atari and Midway machines whose controls were dials,
    # spinners, trackballs, paddles and guns. Chosen over mame2010 after
    # measuring both; see docs/mame-core-comparison-2026-08-21.md, and
    # note in particular that the per-game analog tuning metadata comes
    # from a newer MAME's listxml as data rather than from this core.
    PREFIX=m2003p; REPO=https://github.com/libretro/mame2003-plus-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=MAME2003Plus; LIB=libmame2003_plus_ios.a ;;
vecx)
    # Software vector renderer, forced: the Makefile defaults HAS_GPU=1
    # everywhere but macOS, which would build the GLES2 hardware path
    # this frontend cannot drive (it only hosts the GLES3 contexts
    # Flycast and Mupen64Plus bring). HAS_GPU=0 is also what the macOS
    # lab build produces, so the bench measures the code that ships.
    # The Vectrex BIOS is compiled in (bios/system.h); no firmware.
    PREFIX=vcx; REPO=https://github.com/libretro/libretro-vecx.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=Vecx; LIB=libvecx_ios.a
    MAKEARGS="HAS_GPU=0" ;;
stella2014)
    # The 2014 snapshot of Stella, not modern Stella: this vintage is
    # the one libretro keeps as a light interpreter build, the same
    # weight-class reasoning that picked ProSystem for the 7800. Its
    # check_variables pre-seeds every global with the documented
    # default before reading, so it has no zeroed-globals trap, but
    # the frontend still answers its full table deliberately.
    PREFIX=a26; REPO=https://github.com/libretro/stella2014-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=Stella2014; LIB=libstella2014_ios.a ;;
opera)
    # 3DO. Interpreter-only ARM60 (the core has no dynarec at all), pure
    # software rendering, so it sits on the right side of the JIT
    # boundary, but it is the heaviest interpreter here after the CD
    # consoles: treat any new platform build as a go/no-go measured on
    # hardware, the way PS1 and Dreamcast were, not a batch build.
    # Requires a BIOS (panafz10 family) via RomM, like Saturn.
    PREFIX=opr; REPO=https://github.com/libretro/opera-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=Opera; LIB=libopera_ios.a ;;
beetle_vb)
    # Virtual Boy. Interpreter V810, software rendered, so it clears the
    # JIT boundary without an exception. Its whole identity is
    # stereoscopic red monochrome, which a flat screen cannot reproduce:
    # the core's own vb_color_mode keeps the authentic black & red as the
    # default and vb_anaglyph_preset offers real 3D for anyone with a
    # pair of red/blue glasses. See NativeCoreOptions.virtualBoy.
    PREFIX=vb; REPO=https://github.com/libretro/beetle-vb-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=BeetleVB; LIB=libbeetle_vb_ios.a ;;
melonds)
    # Nintendo DS. The libretro melonDS fork builds interpreter-only for
    # ios-arm64/tvos-arm64 out of the box (no JIT_ARCH set for either),
    # so it clears the JIT boundary without patching. Software renderer,
    # with the core's own threaded-3D option carrying the heavy frames;
    # FreeBIOS is compiled in, so direct boot needs no user firmware.
    # Chosen over desmume2015, whose no-JIT arm64 build does not even
    # link (MMU.cpp calls JIT hooks with DESMUME_JIT=0).
    PREFIX=mds; REPO=https://github.com/libretro/melonDS.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=MelonDS; LIB=libmelonds_ios.a ;;
pcsx_rearmed)
    # platform=ios-arm64 (or tvos-arm64) forces DYNAREC=0 in this core's
    # own Makefile, a pure interpreter build, the same no-JIT exception
    # Beetle Saturn already proved out for its SH-2 core. Confirm on-device
    # speed before treating PS1 as shipped on either platform; this is a
    # go/no-go, not a batch build like the other nine cores.
    PREFIX=psx; REPO=https://github.com/libretro/pcsx_rearmed.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=PCSXReARMed; LIB=libpcsx_rearmed_ios.a ;;
*)
    echo "unknown core: $NAME" >&2; exit 1 ;;
esac

if [ "$PLATFORM" = tvos ]; then
    LIB=$(echo "$LIB" | sed 's/_ios\.a$/_tvos.a/')
fi

# A separate spike/source checkout per platform: these Makefiles drop .o
# files next to the .c files they came from rather than into a
# platform-specific build directory, so reusing one checkout across two
# platforms would silently link a mix of iOS and tvOS objects into
# whichever platform builds second. A fresh clone costs disk, not
# correctness.
SPIKE=spikes/cores/$NAME
if [ "$PLATFORM" != ios ]; then
    SPIKE=spikes/cores/${NAME}-${PLATFORM}
fi
SRC=$SPIKE/src
OUTDIR=RommApp/RommApp/Native/$OUT

if [ ! -d "$SRC" ]; then
    mkdir -p "$SPIKE"
    git clone --depth 1 --recurse-submodules --shallow-submodules "$REPO" "$SRC"
fi

# Beetle PCE Fast's bundled zlib-1.2.11 lost the "!defined(__APPLE__)" guard
# on its classic-Mac-OS fdopen() stub at some point upstream. TARGET_OS_MAC
# is defined on every Apple platform, so the stub now fires unconditionally
# and corrupts stdio.h's real fdopen() declaration under a modern SDK,
# breaking both iOS and tvOS builds, not something new about tvOS. Patch it
# back rather than build a permanently-broken core.
# Applied to every bundled copy rather than one hardcoded path: Beetle
# PCE Fast keeps its zlib under deps/zlib-1.2.11, MAME 2003-Plus under
# src/lib/zlib, and any future core is free to invent a third home.
find "$SRC" -name zutil.h -print0 | while IFS= read -r -d '' ZUTIL_H; do
    sed -i '' 's/#if defined(MACOS) || defined(TARGET_OS_MAC)$/#if (defined(MACOS) || defined(TARGET_OS_MAC)) \&\& !defined(__APPLE__)/' "$ZUTIL_H"
done

if [ "$MAKEFILE" = cmake ]; then
    # mGBA dropped Makefile.libretro; its CMake build has a libretro
    # target instead. Unlike the Makefile-based cores, mGBA's own
    # CMakeLists.txt has no explicit tvOS handling; this relies entirely
    # on CMake's own generic Apple-platform support (CMAKE_SYSTEM_NAME=tvOS
    # picks the appletvos SDK the same way CMAKE_SYSTEM_NAME=iOS picks
    # iphoneos), not on anything mGBA's maintainers tested for tvOS
    # themselves. Confirmed working 2026-08-10, but treat this core's tvOS
    # support as less battle-tested than the ones with a real upstream
    # tvos-arm64 Makefile case.
    CMAKE_SYSTEM_NAME=iOS
    [ "$PLATFORM" = tvos ] && CMAKE_SYSTEM_NAME=tvOS
    cmake -S "$SRC" -B "$SPIKE/build" \
        -DCMAKE_SYSTEM_NAME=$CMAKE_SYSTEM_NAME \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
        -DBUILD_LIBRETRO=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF \
        -DUSE_FFMPEG=OFF -DUSE_SQLITE3=OFF -DUSE_DISCORD_RPC=OFF \
        -DUSE_EDITLINE=OFF -DUSE_ELF=OFF -DBUILD_GLES2=OFF \
        -DBUILD_GLES3=OFF -DBUILD_GL=OFF \
        -DCMAKE_C_FLAGS=-fno-common -DCMAKE_CXX_FLAGS=-fno-common \
        > "$SPIKE/cmake.log" 2>&1
    cmake --build "$SPIKE/build" --target mgba_libretro -j"$JOBS"
    SRC=$SPIKE/build
else
    # -fno-common: an uninitialized non-static global (gambatte's, snes9x's,
    # ProSystem's and GPGX's own "t_snd snd" among them) compiles as a
    # tentative-definition "common" symbol by default, and Apple's ld
    # -exported_symbols_list, the only thing standing between one core's
    # internals and another's, does not localize commons at all, verified
    # directly: a same-named regular symbol got hidden, a common one did
    # not. Two cores that happen to share an internal name silently share
    # one memory address for it instead of colliding at link time, which
    # is far worse: no error, just one core's code quietly reading and
    # writing through the other's differently-shaped struct. Found
    # 2026-08-08 from a real crash: FBNeo and Genesis Plus GX both have an
    # internal "snd", GPGX's audio init was corrupting memory through
    # FBNeo's entirely different one.
    # A PATH-shimmed wrapper, not CC=/CXX= overrides: some of these
    # Makefiles bake their own -arch/-isysroot cross-compile flags
    # directly into CC rather than CFLAGS, and a command-line CC=
    # override replaces that string outright, silently dropping the
    # iOS target and defaulting the final dylib link to the host Mac
    # (found the hard way: "building for macOS, but linking in object
    # file built for iOS"). Shimming the actual cc/c++ binaries on PATH
    # injects -fno-common into every real compiler invocation while
    # leaving whatever CC/CXX string each Makefile computed untouched.
    # Absolute, not $SPIKE/ccwrap: `make -C` changes the process's own
    # working directory before running any recipe, and a relative PATH
    # entry stops resolving to this directory the moment that happens,
    # falling through silently to the real system compiler with no
    # error and no -fno-common. Found 2026-08-10 chasing why a fresh
    # FCEUmm rebuild still shipped 92 unscoped common symbols despite
    # this wrapper existing and working correctly in isolation.
    WRAP="$(pwd)/$SPIKE/ccwrap"
    mkdir -p "$WRAP"
    XCRUN_SDK=iphoneos
    [ "$PLATFORM" = tvos ] && XCRUN_SDK=appletvos
    real_cc=$(xcrun -sdk "$XCRUN_SDK" -find clang)
    real_cxx=$(xcrun -sdk "$XCRUN_SDK" -find clang++)
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cc" > "$WRAP/cc"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cc" > "$WRAP/clang"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cxx" > "$WRAP/c++"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cxx" > "$WRAP/clang++"
    chmod +x "$WRAP"/*
    # MAKEARGS: extra per-core make variables from the case table above.
    # Unset for every core that predates it, so those builds are invoked
    # byte-identically to before it existed.
    PATH="$WRAP:$PATH" make -C "$SRC/$MAKEDIR" -f "$MAKEFILE" platform=$MAKE_PLATFORM $MAKEARGS -j"$JOBS"
fi

DYLIB=$(find "$SRC" -name '*_ios.dylib' | head -1)
if [ -z "$DYLIB" ]; then
    DYLIB=$(find "$SRC" -name '*.dylib' | head -1)
fi
[ -n "$DYLIB" ] || { echo "no dylib produced for $NAME" >&2; exit 1; }

# Generate the prefix wrapper from the app's own libretro.h so the
# script does not depend on where each core keeps its copy.
WRAP=$SPIKE/${PREFIX}_wrapper.c
sed "s/bsat_/${PREFIX}_/g" spikes/BeetleSaturnStatic/bsat_wrapper.c \
    | sed 's|#include "libretro-common/include/libretro.h"|#include "libretro.h"|' \
    > "$WRAP"

cc -arch arm64 -isysroot "$SDK" "$MINVERSION_FLAG" -O2 \
    -I"RommApp/RommApp/Native/Libretro" -c "$WRAP" -o "$SPIKE/wrapper.o"

# Export exactly what the wrapper defines, nothing else. Deriving the
# list from the core dylib (as the Saturn script did) can catch stray
# retro_vfs_* helpers that are not part of the 25 entry points.
nm -g "$SPIKE/wrapper.o" | awk '/ T /{print $NF}' | sort -u > "$SPIKE/exports.txt"

find "$SRC" -name '*.o' ! -path '*wrapper*' > "$SPIKE/objects.txt"
ld -r -arch arm64 -syslibroot "$SDK" \
    "$SPIKE/wrapper.o" $(cat "$SPIKE/objects.txt") \
    -exported_symbols_list "$SPIKE/exports.txt" \
    -o "$SPIKE/combined.o"

mkdir -p "$OUTDIR"
rm -f "$OUTDIR/$LIB"
ar rcs "$OUTDIR/$LIB" "$SPIKE/combined.o"
echo "Wrote $OUTDIR/$LIB"
