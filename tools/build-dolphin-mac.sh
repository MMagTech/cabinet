#!/bin/bash
# Builds Dolphin as a static library for Mac Catalyst, into
# RommApp/RommAppMac/Dolphin/libdolphin_mac.a, and stages its Sys
# folder into RommApp/RommAppMac/DolphinSys.
#
# Same shape as tools/build-pcsx2-mac.sh, and the placement rules are
# the same because the Xcode project synchronises folders straight into
# targets:
#   RommApp/DolphinHost      Cabinet's host layer. Compiled by THIS
#                            script into the library, never by Xcode, so
#                            it sits outside every synchronised folder
#                            and never reaches iOS or tvOS.
#   RommApp/RommAppMac       belongs to the Mac target alone, so the
#                            library, the C bridge header and the Swift
#                            screens go there.
#                            DolphinSys is a sibling rather than a
#                            subfolder because it has to be listed in
#                            explicitFolders to reach the bundle with
#                            its directory structure intact, the same
#                            way PCSX2Resources and Resources/PPSSPP
#                            already are.
#
# What is turned off, and why:
#   ENABLE_QT      the frontend is Cabinet's. Unlike PCSX2 this is a
#                  first-class option and the emulator is already
#                  factored into libraries, so nothing is carved out.
#   ENABLE_NOGUI   the other upstream frontend, equally unwanted
#   ENABLE_VULKAN  the Mac draws through Dolphin's own Metal renderer
#   ENABLE_CUBEB   its vendored copy will not build for iOS-family
#                  targets; Cabinet supplies a SoundStream instead.
#                  See tools/patch-dolphin-mac.py.
#   ENABLE_SDL     SDL3 does not survive Catalyst, the same wall PS2 hit
#   ENABLE_LLVM, AUTOUPDATE, DISCORD, MGBA, RETRO_ACHIEVEMENTS,
#   ANALYTICS, UPNP, TESTS   desktop app furniture, none of it wanted
#
# THE TRAP, and it produced a fake green build the first time: .mm
# files compile as OBJCXX and do NOT read CMAKE_CXX_FLAGS. Without
# CMAKE_OBJC_FLAGS and CMAKE_OBJCXX_FLAGS the Objective-C++ half builds
# for native macOS while the C++ half builds for Catalyst, and the run
# reports "100% Built target" with zero errors while libvideometal.a is
# stamped platform 1 and could never link into the app. This script
# verifies the platform of every archive at the end for exactly that
# reason. Never trust the exit code alone here.
#
# CMAKE_IGNORE_PREFIX_PATH keeps Homebrew out, the standing guard PS2
# earned. Dolphin needs it far less, every one of its dependencies is
# vendored in Externals, but a stray system hit would be just as
# poisonous.
set -e
cd "$(dirname "$0")/.."

ROOT="$PWD"
SPIKE="$ROOT/spikes/dolphin"
SRC="$SPIKE/src"
BUILD="$SPIKE/build-macabi"
HOST="$ROOT/RommApp/DolphinHost"
OUT="$ROOT/RommApp/RommAppMac/Dolphin"
SYS="$ROOT/RommApp/RommAppMac/DolphinSys"
REPO=https://github.com/dolphin-emu/dolphin.git
# Pinned. Dolphin moves fast and this is the commit the Catalyst walls
# were found and measured against; a float could reintroduce any of
# them silently. See spikes/dolphin/notes/SPIKE.md.
PIN=a1e636d
SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=arm64-apple-ios18.0-macabi
JOBS=$(sysctl -n hw.ncpu)

# Catalyst keeps UIKit and the rest of the iOS frameworks in the macOS
# SDK under System/iOSSupport, and clang only looks there when told to.
# Xcode passes these two for every Catalyst target; a bare cmake build
# does not, and the symptom is UIKit/UIKit.h simply not existing.
CATALYST_PATHS="-iframework $SDK/System/iOSSupport/System/Library/Frameworks -isystem $SDK/System/iOSSupport/usr/include"
# -fno-common for the same reason every libretro core here gets it:
# the merge below hides Dolphin's internals behind an exported
# symbols list, and Apple's ld does not localize common symbols at
# all. Two vendored C libraries sharing an uninitialized global name
# would silently share one address instead of colliding at link
# time, which is far worse than an error.
FLAGS="-target $TARGET $CATALYST_PATHS -fno-common -DCABINET_CATALYST=1"

if [ ! -d "$SRC" ]; then
	mkdir -p "$SPIKE"
	git clone --recurse-submodules "$REPO" "$SRC"
	git -C "$SRC" checkout "$PIN"
	git -C "$SRC" submodule update --init --recursive
fi

HEAD=$(git -C "$SRC" rev-parse --short HEAD)
if [ "$HEAD" != "$PIN" ]; then
	echo "dolphin tree is at $HEAD, expected the pinned $PIN" >&2
	exit 1
fi

python3 "$ROOT/tools/patch-dolphin-mac.py" "$SRC"

cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_SYSTEM_NAME=Darwin \
	-DCMAKE_SYSTEM_PROCESSOR=arm64 \
	-DCMAKE_OSX_SYSROOT="$SDK" \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew \
	-DCMAKE_C_FLAGS="$FLAGS" \
	-DCMAKE_CXX_FLAGS="$FLAGS" \
	-DCMAKE_OBJC_FLAGS="$FLAGS" \
	-DCMAKE_OBJCXX_FLAGS="$FLAGS" \
	-DCABINET_CATALYST=ON \
	-DENABLE_QT=OFF -DENABLE_NOGUI=OFF -DENABLE_TESTS=OFF \
	-DENABLE_VULKAN=OFF -DENABLE_LLVM=OFF -DENABLE_AUTOUPDATE=OFF \
	-DENABLE_CUBEB=OFF -DENABLE_SDL=OFF \
	-DUSE_DISCORD_PRESENCE=OFF -DUSE_MGBA=OFF \
	-DUSE_RETRO_ACHIEVEMENTS=OFF -DENABLE_ANALYTICS=OFF \
	-DUSE_UPNP=OFF -DMACOS_CODE_SIGNING=OFF

# uicommon rather than core: it sits on top and pulls core, common,
# videocommon, videometal, discio, inputcommon and audiocommon with it,
# and Cabinet needs its Init and its controller setup.
cmake --build "$BUILD" --target uicommon --parallel "$JOBS"

# Cabinet's host layer, compiled here rather than by Xcode. It needs
# Dolphin's headers, and those live in a git-ignored spike tree that no
# Xcode target can reasonably be pointed at; compiling it here keeps the
# project file free of any path into spikes/.
HOST_OBJ="$BUILD/cabinet-host"
mkdir -p "$HOST_OBJ"
HOST_INCLUDES="-I$SRC/Source/Core -I$BUILD/exports -I$SRC/Externals/fmt/fmt/include -I$SRC/Externals/ed25519"
# Dolphin's own architecture defines, which its CMake passes to every
# translation unit and a hand-rolled compile does not. Several headers
# select a CPU context struct from them and #error out otherwise, so
# leaving them off fails with "No context definition for architecture"
# rather than anything that names the cause.
HOST_DEFINES="-D_M_ARM_64=1 -D_ARCH_64=1"
for source in "$HOST"/*.cpp "$HOST"/*.mm; do
	[ -e "$source" ] || continue
	name=$(basename "$source")
	clang++ -std=c++23 -O2 $FLAGS -isysroot "$SDK" \
		$HOST_DEFINES $HOST_INCLUDES -c "$source" -o "$HOST_OBJ/${name%.*}.o"
done

# One archive per emulator, the way every other core in this app ships,
# and like the libretro cores it exports ONLY Cabinet's own entry points.
#
# That scoping is not tidiness. PCSX2 and Dolphin both vendor ImGui, and
# both end up in this one binary: a plain libtool merge collides on
# every ImGui symbol at the app link, and quieter collisions than that
# are the ones to worry about. `ld -r` with an exported symbols list is
# the same mechanism tools/build-core.sh uses to let twenty-three cores
# share a process, and it has the useful side effect of pulling only the
# objects the host layer actually reaches.
#
# Cabinet's own objects come FIRST: they are the roots of the reachable
# set, and ld pulls archive members to satisfy them rather than the
# other way round.
mkdir -p "$OUT"
rm -f "$OUT/libdolphin_mac.a"
EXPORTS="$BUILD/cabinet-exports.txt"
cat > "$EXPORTS" <<'SYMBOLS'
_CabinetDolphinRun
_CabinetDolphinSetSurfaceLayer
_CabinetDolphinSetSurfaceSize
_CabinetDolphinSetPad
_CabinetDolphinSetPaused
_CabinetDolphinRequestStop
_CabinetDolphinIsRunning
_CabinetDolphinGetMetrics
_CabinetDolphinScreenshot
SYMBOLS
LIBS=$(find "$BUILD" -name '*.a' | sort)
ld -r -arch arm64 -syslibroot "$SDK" \
	-exported_symbols_list "$EXPORTS" \
	"$HOST_OBJ"/*.o $LIBS \
	-o "$BUILD/cabinet-dolphin.o"
ar rcs "$OUT/libdolphin_mac.a" "$BUILD/cabinet-dolphin.o"

# The platform check the fake green build earned. Every object in the
# merged archive must be macCatalyst (platform 6); a single native macOS
# object means the OBJC flags above did not reach something, and the
# failure would otherwise surface much later as an Xcode link error
# nobody would connect to this script.
PLATFORMS=$(otool -l "$OUT/libdolphin_mac.a" | awk '/^ *platform /{print $2}' | sort -u)
if [ "$PLATFORMS" != "6" ]; then
	echo "libdolphin_mac.a contains non-Catalyst objects (platforms: $PLATFORMS)" >&2
	exit 1
fi

# Dolphin reads its GC fonts, shaders, game settings and profiles from a
# Sys folder at runtime, and its GameCube boot needs the IPL fonts in
# particular. Staged here so the Xcode target has one directory to
# bundle. Wii/ comes along: it is 3 MB, it is where a Wii NAND would go,
# and pruning it would be the kind of saving that breaks something later
# for nothing.
rm -rf "$SYS"
mkdir -p "$SYS"
cp -R "$SRC/Data/Sys/" "$SYS/"

echo "Wrote $OUT/libdolphin_mac.a"
ls -lh "$OUT/libdolphin_mac.a"
echo "Wrote $SYS"
