#!/bin/sh
# Builds RommApp/RommApp/Native/FBNeo/libfbneo_libretro_<platform>.a from
# the FinalBurn Neo sources. Usage: tools/build-fbneo.sh [ios|tvos],
# defaults to ios.
#
# Unlike every later core, FBNeo keeps its real unprefixed retro_* names
# rather than getting a <prefix>_retro_* wrapper (see
# native-player-frontend-architecture in project memory: FBNeo was the
# first core, built before the prefixing convention existed, and
# FBNeoCore.mm calls its symbols directly by their real names). The fix
# this script replicates ("Scope FBNeo's exported symbols like every
# other core", 2026-08-10) is narrower than the other cores' treatment:
# same -exported_symbols_list scoping down to the real ~54 retro_*/
# retro_vfs_* entry points libretro-common exports, no renaming.
#
# No fresh git clone here: FBNeo's full source is large (a couple hundred
# MB) and slow to clone, and this script is meant to run against the
# existing spikes/FBNeoStatic/FBNeo checkout, `make clean`ing it first
# since object files from a previous platform's build would otherwise
# silently mix in.
set -e

cd "$(dirname "$0")/.."
PLATFORM=${1:-ios}

case "$PLATFORM" in
ios)
    SDK=$(xcrun -sdk iphoneos --show-sdk-path)
    MAKE_PLATFORM=ios9 ;;
tvos)
    SDK=$(xcrun -sdk appletvos --show-sdk-path)
    MAKE_PLATFORM=tvos-arm64 ;;
*)
    echo "unknown platform: $PLATFORM (expected ios or tvos)" >&2; exit 1 ;;
esac

SPIKE=spikes/FBNeoStatic
SRC=$SPIKE/FBNeo
LIBRETRO_DIR=$SRC/src/burner/libretro
OUT=RommApp/RommApp/Native/FBNeo
LIB=libfbneo_libretro_${PLATFORM}.a

if [ ! -d "$SRC" ]; then
    mkdir -p "$SPIKE"
    git clone --depth 1 https://github.com/libretro/FBNeo.git "$SRC"
fi

make -C "$LIBRETRO_DIR" clean
make -C "$LIBRETRO_DIR" platform=$MAKE_PLATFORM -j"$(sysctl -n hw.ncpu)"

DYLIB=$(find "$LIBRETRO_DIR" -maxdepth 1 -name '*.dylib' | head -1)
[ -n "$DYLIB" ] || { echo "no dylib produced" >&2; exit 1; }

WORK=$SPIKE/work-${PLATFORM}
mkdir -p "$WORK"

# Derive the export list from the dylib itself, not a hand-maintained
# list: this catches the real retro_* entry points plus the retro_vfs_*
# helpers libretro-common provides, which are not part of the 25-function
# core API but are real symbols other code in the app may reference.
nm -g "$DYLIB" 2>/dev/null | awk '/ T _retro_/{print $NF}' | sort -u > "$WORK/fbneo_exports.txt"

find "$SRC/src" -name '*.o' > "$WORK/objects.txt"
ld -r -arch arm64 -syslibroot "$SDK" \
    $(cat "$WORK/objects.txt") \
    -exported_symbols_list "$WORK/fbneo_exports.txt" \
    -o "$WORK/fbneo_combined.o"

mkdir -p "$OUT"
rm -f "$OUT/$LIB"
ar rcs "$OUT/$LIB" "$WORK/fbneo_combined.o"
rm -rf "$WORK"
echo "Wrote $OUT/$LIB"
