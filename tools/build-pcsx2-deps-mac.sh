#!/bin/bash
# Builds PCSX2's external dependencies as static libraries for Mac
# Catalyst, into spikes/cores/pcsx2-deps/macabi.
#
# PCSX2 is a macOS app and every prebuilt of these libraries is
# arm64-apple-macos, which a Catalyst binary cannot link. So this is
# upstream's own build-dependencies-universal.sh with three changes:
# every compile carries arm64-apple-ios18.0-macabi against the macOS
# SDK, the libraries come out static rather than dylibs, and the list
# is cut to what a Cabinet build actually needs.
#
# Cut, and why:
#   Qt         the frontend is Cabinet's, ENABLE_QT_UI=OFF
#   shaderc    Vulkan only, and the Mac draws with PCSX2's Metal renderer
#   MoltenVK   same
#   ffmpeg     video capture only, not a player feature
#   SDL3       audio goes through the vendored cubeb, input through
#              Cabinet's GameControllerManager. Dropping it also drops
#              the one dependency here with a Cocoa backend, which is
#              the one that would not have survived Catalyst.
#
# Versions and checksums are upstream's, verbatim.
set -e
cd "$(dirname "$0")/.."

DEPS="$PWD/spikes/cores/pcsx2-deps"
SRC="$DEPS/src"
PREFIX="$DEPS/macabi"
SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=arm64-apple-ios18.0-macabi
JOBS=$(sysctl -n hw.ncpu)

mkdir -p "$SRC" "$PREFIX"
cd "$SRC"

FREETYPE=2.14.3
HARFBUZZ=14.2.0
ZSTD=1.5.7
LZ4=1.10.0
LIBPNG=1.6.58
LIBJPEGTURBO=3.1.4.1
LIBWEBP=1.6.0
PLUTOVG=1.3.2
PLUTOSVG=0.0.7
RAPIDYAML=0.12.1

grep . > SHASUMS <<EOF
36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f  freetype-$FREETYPE.tar.xz
c652d5d94971031654ab3989891a490a895d3e3f2b71171c62692b28e94b1b93  harfbuzz-$HARFBUZZ.tar.gz
eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3  zstd-$ZSTD.tar.gz
537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b  lz4-$LZ4.tar.gz
28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775  libpng-$LIBPNG.tar.xz
ecae8008e2cc9ade2f2c1bb9d5e6d4fb73e7c433866a056bd82980741571a022  libjpeg-turbo-$LIBJPEGTURBO.tar.gz
e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564  libwebp-$LIBWEBP.tar.gz
7bd4e79ce18b1d47517e7e91fbb7cf19d4f01942804a519bc7c0bf32b6325dd5  plutovg-$PLUTOVG.tar.gz
78561b571ac224030cdc450ca2986b4de915c2ba7616004a6d71a379bffd15f3  plutosvg-$PLUTOSVG.tar.gz
e9efcdd17f86287748793cf21d106e461fcad8d103a3e5a23632afe93828660d  rapidyaml-$RAPIDYAML-src.tgz
EOF

if ! shasum -sa 256 --check SHASUMS 2> /dev/null; then
	curl -L --retry 3 \
		-O "https://sourceforge.net/projects/freetype/files/freetype2/$FREETYPE/freetype-$FREETYPE.tar.xz" \
		-O "https://github.com/harfbuzz/harfbuzz/archive/$HARFBUZZ/harfbuzz-$HARFBUZZ.tar.gz" \
		-O "https://github.com/facebook/zstd/releases/download/v$ZSTD/zstd-$ZSTD.tar.gz" \
		-O "https://github.com/lz4/lz4/releases/download/v$LZ4/lz4-$LZ4.tar.gz" \
		-O "https://downloads.sourceforge.net/project/libpng/libpng16/$LIBPNG/libpng-$LIBPNG.tar.xz" \
		-O "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$LIBJPEGTURBO/libjpeg-turbo-$LIBJPEGTURBO.tar.gz" \
		-O "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$LIBWEBP.tar.gz" \
		-O "https://github.com/sammycage/plutovg/archive/v$PLUTOVG/plutovg-$PLUTOVG.tar.gz" \
		-O "https://github.com/sammycage/plutosvg/archive/v$PLUTOSVG/plutosvg-$PLUTOSVG.tar.gz" \
		-O "https://github.com/biojppm/rapidyaml/releases/download/v$RAPIDYAML/rapidyaml-$RAPIDYAML-src.tgz"
fi

shasum -a 256 --check --strict SHASUMS

# CMAKE_OSX_DEPLOYMENT_TARGET is emptied on purpose: cmake turns it into
# -mmacosx-version-min, which contradicts the macabi target triple and
# makes clang pick the wrong platform.
# CMAKE_OSX_DEPLOYMENT_TARGET is emptied on purpose: cmake turns it into
# -mmacosx-version-min, which contradicts the macabi target triple and
# makes clang pick the wrong platform.
COMMON=(
	-DCMAKE_BUILD_TYPE=Release
	-DCMAKE_SYSTEM_NAME=Darwin
	-DCMAKE_SYSTEM_PROCESSOR=arm64
	-DCMAKE_OSX_ARCHITECTURES=arm64
	-DCMAKE_OSX_SYSROOT="$SDK"
	-DCMAKE_OSX_DEPLOYMENT_TARGET=
	-DCMAKE_C_FLAGS="-target $TARGET -fno-common"
	-DCMAKE_CXX_FLAGS="-target $TARGET -fno-common"
	-DCMAKE_PREFIX_PATH="$PREFIX"
	-DCMAKE_INSTALL_PREFIX="$PREFIX"
	-DBUILD_SHARED_LIBS=OFF
)

build() {
	dir=$1; shift
	src=$1; shift
	echo "=== $dir ==="
	cmake "${COMMON[@]}" "$@" -B "$SRC/$dir/build-macabi" "$src"
	cmake --build "$SRC/$dir/build-macabi" --parallel "$JOBS"
	cmake --install "$SRC/$dir/build-macabi"
}

unpack() {
	rm -fr "$SRC/$1"
	tar xf "$SRC/$2"
}

echo "Installing Zstd..."
unpack "zstd-$ZSTD" "zstd-$ZSTD.tar.gz"
build "zstd-$ZSTD" "$SRC/zstd-$ZSTD/build/cmake" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON

echo "Installing LZ4..."
unpack "lz4-$LZ4" "lz4-$LZ4.tar.gz"
build "lz4-$LZ4" "$SRC/lz4-$LZ4/build/cmake" -DLZ4_BUILD_CLI=OFF -DLZ4_BUILD_LEGACY_LZ4C=OFF

echo "Installing libpng..."
unpack "libpng-$LIBPNG" "libpng-$LIBPNG.tar.xz"
build "libpng-$LIBPNG" "$SRC/libpng-$LIBPNG" -DPNG_TESTS=OFF -DPNG_FRAMEWORK=OFF -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_ARM_NEON=on -DPNG_TOOLS=OFF

echo "Installing libjpegturbo..."
unpack "libjpeg-turbo-$LIBJPEGTURBO" "libjpeg-turbo-$LIBJPEGTURBO.tar.gz"
build "libjpeg-turbo-$LIBJPEGTURBO" "$SRC/libjpeg-turbo-$LIBJPEGTURBO" -DENABLE_STATIC=ON -DENABLE_SHARED=OFF -DWITH_TURBOJPEG=OFF

echo "Installing WebP..."
unpack "libwebp-$LIBWEBP" "libwebp-$LIBWEBP.tar.gz"
build "libwebp-$LIBWEBP" "$SRC/libwebp-$LIBWEBP" \
	-DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
	-DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
	-DWEBP_BUILD_EXTRAS=OFF

# Freetype and HarfBuzz depend on each other, so freetype is built
# twice, upstream's own dance.
echo "Building FreeType without HarfBuzz..."
unpack "freetype-$FREETYPE" "freetype-$FREETYPE.tar.xz"
build "freetype-$FREETYPE" "$SRC/freetype-$FREETYPE" \
	-DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON -DFT_DISABLE_BZIP2=TRUE -DFT_DISABLE_BROTLI=TRUE -DFT_DISABLE_HARFBUZZ=TRUE

echo "Building HarfBuzz..."
unpack "harfbuzz-$HARFBUZZ" "harfbuzz-$HARFBUZZ.tar.gz"
build "harfbuzz-$HARFBUZZ" "$SRC/harfbuzz-$HARFBUZZ" -DHB_BUILD_UTILS=OFF -DHB_BUILD_GPU=OFF -DHB_HAVE_FREETYPE=ON

echo "Building FreeType with HarfBuzz..."
unpack "freetype-$FREETYPE" "freetype-$FREETYPE.tar.xz"
build "freetype-$FREETYPE" "$SRC/freetype-$FREETYPE" \
	-DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON -DFT_DISABLE_BZIP2=TRUE -DFT_DISABLE_BROTLI=TRUE -DFT_REQUIRE_HARFBUZZ=TRUE

echo "Installing plutovg..."
unpack "plutovg-$PLUTOVG" "plutovg-$PLUTOVG.tar.gz"
build "plutovg-$PLUTOVG" "$SRC/plutovg-$PLUTOVG"

echo "Installing plutosvg..."
unpack "plutosvg-$PLUTOSVG" "plutosvg-$PLUTOSVG.tar.gz"
build "plutosvg-$PLUTOSVG" "$SRC/plutosvg-$PLUTOSVG" -DPLUTOSVG_ENABLE_FREETYPE=ON -DPLUTOSVG_BUILD_EXAMPLES=OFF

echo "Installing rapidyaml..."
rm -fr "$SRC/rapidyaml-$RAPIDYAML"
mkdir -p "$SRC/rapidyaml-$RAPIDYAML"
tar xf "$SRC/rapidyaml-$RAPIDYAML-src.tgz" -C "$SRC/rapidyaml-$RAPIDYAML" --strip-components=1
build "rapidyaml-$RAPIDYAML" "$SRC/rapidyaml-$RAPIDYAML" -DRYML_BUILD_TESTS=OFF -DRYML_BUILD_TOOLS=OFF -DRYML_BUILD_API=OFF

echo
echo "Wrote $PREFIX/lib"
ls "$PREFIX/lib" | grep '\.a$' || true
