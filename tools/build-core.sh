#!/bin/sh
# Generic native core builder, the batch generalisation of
# build-beetle-saturn.sh. Same shape of output for every core: a single
# merged relocatable object whose only exported symbols are
# <prefix>_retro_* forwarders, so any number of cores can link into one
# binary without their retro_* names (or bundled zlib and friends)
# colliding. Usage: tools/build-core.sh <core-name>
set -e

cd "$(dirname "$0")/.."
NAME=$1
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
JOBS=$(sysctl -n hw.ncpu)

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
pcsx_rearmed)
    # platform=ios-arm64 forces DYNAREC=0 in this core's own Makefile,
    # a pure interpreter build, the same no-JIT exception Beetle Saturn
    # already proved out for its SH-2 core. Confirm on-device speed
    # before treating PS1 as shipped; this is a go/no-go, not a batch
    # build like the other nine cores.
    PREFIX=psx; REPO=https://github.com/libretro/pcsx_rearmed.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=PCSXReARMed; LIB=libpcsx_rearmed_ios.a ;;
*)
    echo "unknown core: $NAME" >&2; exit 1 ;;
esac

SPIKE=spikes/cores/$NAME
SRC=$SPIKE/src
OUTDIR=RommApp/RommApp/Native/$OUT

if [ ! -d "$SRC" ]; then
    mkdir -p "$SPIKE"
    git clone --depth 1 --recurse-submodules --shallow-submodules "$REPO" "$SRC"
fi

if [ "$MAKEFILE" = cmake ]; then
    # mGBA dropped Makefile.libretro; its CMake build has a libretro
    # target instead.
    cmake -S "$SRC" -B "$SPIKE/build" \
        -DCMAKE_SYSTEM_NAME=iOS \
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
    WRAP=$SPIKE/ccwrap
    mkdir -p "$WRAP"
    real_cc=$(xcrun -sdk iphoneos -find clang)
    real_cxx=$(xcrun -sdk iphoneos -find clang++)
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cc" > "$WRAP/cc"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cc" > "$WRAP/clang"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cxx" > "$WRAP/c++"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cxx" > "$WRAP/clang++"
    chmod +x "$WRAP"/*
    PATH="$WRAP:$PATH" make -C "$SRC/$MAKEDIR" -f "$MAKEFILE" platform=ios-arm64 -j"$JOBS"
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

cc -arch arm64 -isysroot "$SDK" -miphoneos-version-min=18.0 -O2 \
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
