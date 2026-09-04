#!/bin/bash
# Builds PCSX2 as a static library for Mac Catalyst, into
# RommApp/RommAppMac/PCSX2/libpcsx2_mac.a.
#
# Note where the pieces live, because the Xcode project synchronises
# folders straight into targets and that decides placement:
#   RommApp/PCSX2Host      Cabinet's host layer. Compiled by THIS
#                          script into the library, never by Xcode, so
#                          it sits outside every synchronised folder.
#   RommApp/RommAppMac     belongs to the Mac target alone, so the
#                          library and PCSX2's resources go there and
#                          no iOS or tvOS build ever sees them.
#                          PCSX2Resources is a sibling rather than a
#                          subfolder because it has to be listed in
#                          explicitFolders to reach the bundle with its
#                          directory structure intact, the same way
#                          Resources/PPSSPP already is.
# Putting either under RommApp/RommApp would compile them into all
# three targets, which is how this was first laid out and wrong.
#
# The source is the isztldav fork, which adds the ARM64 JIT
# recompilers upstream stubs out on Apple Silicon. Pinned to the exact
# commit the 2026-08-30 numbers came from; see the memory note and
# spikes/ps2-jitless/notes/SPIKE.md. About 23k lines of new arm64
# emitter against stock 2.8-dev, and its README says that emitter was
# translated with LLM help, so the pin matters more here than usual:
# never float this to the fork's HEAD without re-measuring.
#
# Run tools/build-pcsx2-deps-mac.sh first; this needs its output.
#
# What is turned off, and why:
#   ENABLE_QT_UI   the frontend is Cabinet's
#   ENABLE_TESTS   googletest builds a host binary, pointless here
#   USE_VULKAN     the Mac draws through PCSX2's own Metal renderer,
#                  which also spares us shaderc and MoltenVK
#   SDL3           does not survive Catalyst. See the patches below.
#
# CMAKE_IGNORE_PREFIX_PATH keeps Homebrew out. This matters more than
# it looks: a find_package that succeeds against /opt/homebrew pulls
# native macOS dylibs into a Catalyst link and, worse, puts
# /opt/homebrew/include ahead of PCSX2's own vendored headers. FFmpeg
# did exactly that and quietly replaced the bundled fmt with
# Homebrew's.
set -e
cd "$(dirname "$0")/.."

ROOT="$PWD"
SRC="$ROOT/spikes/cores/pcsx2"
DEPS="$ROOT/spikes/cores/pcsx2-deps/macabi"
HOST="$ROOT/RommApp/PCSX2Host"
OUT="$ROOT/RommApp/RommAppMac/PCSX2"
RES="$ROOT/RommApp/RommAppMac/PCSX2Resources"
PIN=c89cb8ae0cdef534de530ebfa346eaebc39aba51
SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=arm64-apple-ios18.0-macabi
JOBS=$(sysctl -n hw.ncpu)

# Catalyst keeps UIKit and the rest of the iOS frameworks in the macOS
# SDK under System/iOSSupport, and clang only looks there when told to.
# Xcode passes these two for every Catalyst target; a bare cmake build
# does not, and the symptom is UIKit/UIKit.h simply not existing.
CATALYST_PATHS="-iframework $SDK/System/iOSSupport/System/Library/Frameworks -isystem $SDK/System/iOSSupport/usr/include"

[ -d "$SRC" ] || { echo "no pcsx2 tree at $SRC" >&2; exit 1; }
[ -d "$DEPS/lib" ] || { echo "no deps at $DEPS, run tools/build-pcsx2-deps-mac.sh" >&2; exit 1; }

HEAD=$(git -C "$SRC" rev-parse HEAD)
if [ "$HEAD" != "$PIN" ]; then
	echo "pcsx2 tree is at $HEAD, expected the pinned $PIN" >&2
	exit 1
fi

python3 "$ROOT/tools/patch-pcsx2-mac.py" "$SRC" "$HOST"

cmake \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_SYSTEM_NAME=Darwin \
	-DCMAKE_SYSTEM_PROCESSOR=arm64 \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_SYSROOT="$SDK" \
	-DCMAKE_OSX_DEPLOYMENT_TARGET= \
	-DCMAKE_C_FLAGS="-target $TARGET -fno-common $CATALYST_PATHS" \
	-DCMAKE_CXX_FLAGS="-target $TARGET -fno-common $CATALYST_PATHS" \
	-DCMAKE_PREFIX_PATH="$DEPS" \
	-DCABINET_HOST_DIR="$HOST" \
	-DCABINET_DEPS_DIR="$DEPS" \
	-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew \
	-DENABLE_QT_UI=OFF \
	-DENABLE_TESTS=OFF \
	-DENABLE_GSRUNNER=OFF \
	-DUSE_VULKAN=OFF \
	-DUSE_LINKED_FFMPEG=OFF \
	-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
	-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
	-B "$SRC/build-macabi" "$SRC"

cmake --build "$SRC/build-macabi" --target PCSX2 --parallel "$JOBS"

# PCSX2 links a pile of vendored 3rdparty archives beside its own, and
# Xcode wants one file per core the way every other core in this app
# ships. Merge them, ours last so it wins on any duplicate symbol.
# The Metal shaders. PCSX2 builds these only as part of its own app
# bundle, which this build never produces, and it targets macOS rather
# than Catalyst. So they are built here instead, and they are not
# optional: even the null renderer creates a Metal device, so PCSX2
# will not start without finding them.
#
# Three of them, upstream's own set. GSDeviceMTL asks for the newest
# first and falls back, so a machine that cannot run Metal23 still gets
# a library it understands.
SHADERS="cas convert present merge misc interlace tfx fxaa"
build_metallib() {
	std=$1
	name=$2
	air=""
	mkdir -p "$SRC/build-macabi/metal/$name"
	for shader in $SHADERS; do
		out="$SRC/build-macabi/metal/$name/$shader.air"
		xcrun metal -ffast-math -std="$std" -target "air64-apple-ios18.0-macabi" \
			-o "$out" -c "$SRC/pcsx2/GS/Renderers/Metal/$shader.metal"
		air="$air $out"
	done
	xcrun metallib -o "$RES/$name.metallib" $air
}

# PCSX2 reads its game database, fonts and post-processing shaders from
# a resources folder at runtime, and refuses to start without it. It is
# staged here so the Xcode target has one directory to bundle.
rm -rf "$RES"
mkdir -p "$RES"
cp -R "$SRC/bin/resources/" "$RES/"

build_metallib macos-metal2.0 default
build_metallib macos-metal2.2 Metal22
build_metallib macos-metal2.3 Metal23
echo "Wrote $RES"

mkdir -p "$OUT"
rm -f "$OUT/libpcsx2_mac.a"
# The build's own archives, plus exactly the external ones PCSX2
# actually links. Naming them rather than globbing the deps folder is
# deliberate: it also ships libpng16.a beside libpng.a and
# libwebpdecoder.a beside libwebp.a, and merging both of either pair
# gives duplicate symbols.
LIBS=$(find "$SRC/build-macabi" -name '*.a' | sort)
for dep in freetype jpeg lz4 plutosvg plutovg png ryml sharpyuv webp zstd; do
	LIBS="$LIBS $DEPS/lib/lib$dep.a"
done
libtool -static -o "$OUT/libpcsx2_mac.a" $LIBS
echo "Wrote $OUT/libpcsx2_mac.a"
ls -lh "$OUT/libpcsx2_mac.a"
