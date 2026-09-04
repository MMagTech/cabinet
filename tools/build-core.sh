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
mac)
    # Mac Catalyst. No libretro Makefile knows the macabi triple, so
    # this rides each core's ios-arm64 case, which picks the right
    # sources and Apple defines, and the compiler shim below rewrites
    # the platform flags: the iOS minimum-version and sysroot flags are
    # stripped and the Catalyst target plus the macOS SDK take their
    # place. The objects come out arm64-apple-ios-macabi, which is what
    # the RommAppMac target links; plain macOS objects would be
    # rejected by its linker.
    SDK=$(xcrun -sdk macosx --show-sdk-path)
    MINVERSION_FLAG="-target arm64-apple-ios18.0-macabi"
    MAKE_PLATFORM=ios-arm64 ;;
*)
    echo "unknown platform: $PLATFORM (expected ios, tvos or mac)" >&2; exit 1 ;;
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
gw)
    # Game & Watch, via MADrigal's simulators compiled to Lua. Plain Lua
    # 5.3 interpreter, no LuaJIT, so it clears the JIT boundary without
    # an exception. iOS-ONLY by decision, recorded in docs/building.md
    # 2026-08-25: small per-game canvases (562x374) go soft at 4K and the
    # artwork draws the whole handheld. Reversible; upstream has a
    # tvos-arm64 case if it ever reverses.
    PREFIX=gw; REPO=https://github.com/libretro/gw-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=GW; LIB=libgw_ios.a ;;
vemulator)
    # The Dreamcast VMU itself, as a machine: an LC86K interpreter with a
    # 48x32 LCD, the smallest core here by two orders of magnitude. Plays
    # the minigames Dreamcast games download onto their save card (Chao
    # Adventure and friends), booting them straight out of the same
    # 128KB card image the DC save sync already stores; with
    # enable_flash_write on it commits every flash write back into that
    # file in real time, so the round-trip is the core's own behavior.
    # HLE boot, no BIOS file ever. iOS-ONLY by decision, recorded in
    # docs/building.md 2026-08-29: the minigame's identity is the thing
    # you take away from the TV, and 48x32 is absurd on a living room
    # screen. Spike notes: spikes/vmu/notes-SPIKE.md.
    PREFIX=vmu; REPO=https://github.com/libretro/vemulator-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=VeMUlator; LIB=libvemulator_ios.a ;;
melonds)
    # Nintendo DS. The libretro melonDS fork builds interpreter-only for
    # ios-arm64/tvos-arm64 out of the box (no JIT_ARCH set for either),
    # so it clears the JIT boundary without patching. Software renderer,
    # with the core's own threaded-3D option carrying the heavy frames;
    # FreeBIOS is compiled in, so direct boot needs no user firmware.
    # Chosen over desmume2015, whose no-JIT arm64 build does not even
    # link (MMU.cpp calls JIT hooks with DESMUME_JIT=0).
    #
    # On Mac only, JIT_ARCH=aarch64 is added below. melonDS's own ARM64
    # recompiler already knows Apple Silicon: it allocates its code
    # buffer with MAP_JIT and toggles W^X through
    # pthread_jit_write_protect_np, so this is the flag the Mac was
    # missing rather than a port. iOS and tvOS pass no MAKEARGS at all
    # and build byte-identically to before.
    PREFIX=mds; REPO=https://github.com/libretro/melonDS.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=MelonDS; LIB=libmelonds_ios.a
    if [ "$PLATFORM" = mac ]; then MAKEARGS="JIT_ARCH=aarch64"; fi ;;
pcsx_rearmed)
    # platform=ios-arm64 (or tvos-arm64) forces DYNAREC=0 in this core's
    # own Makefile, a pure interpreter build, the same no-JIT exception
    # Beetle Saturn already proved out for its SH-2 core. Confirm on-device
    # speed before treating PS1 as shipped on either platform; this is a
    # go/no-go, not a batch build like the other nine cores.
    #
    # On Mac only, DYNAREC=ari64 is added below, overriding that forced
    # 0 from the command line. Unlike N64's, this recompiler is already
    # ported to Apple: linkage_arm64.S goes through ESYM() for the
    # Mach-O underscore prefix and guards its ELF-only directives, and
    # new_dynarec_config.h turns on NO_WRITE_EXEC for __MACH__ so the
    # code cache is toggled between writable and executable rather than
    # mapped as both. iOS and tvOS pass no MAKEARGS and keep the
    # interpreter.
    PREFIX=psx; REPO=https://github.com/libretro/pcsx_rearmed.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=PCSXReARMed; LIB=libpcsx_rearmed_ios.a
    if [ "$PLATFORM" = mac ]; then MAKEARGS="DYNAREC=ari64"; fi ;;
*)
    echo "unknown core: $NAME" >&2; exit 1 ;;
esac

if [ "$PLATFORM" = tvos ]; then
    LIB=$(echo "$LIB" | sed 's/_ios\.a$/_tvos.a/')
fi
if [ "$PLATFORM" = mac ]; then
    LIB=$(echo "$LIB" | sed 's/_ios\.a$/_mac.a/')
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

# melonDS's libretro build has no background flush thread (__LIBRETRO__
# compiles it out) and instead debounce-flushes the .sav at the end of
# every retro_run, two seconds after the game's last SRAM write. Its
# retro_unload_game is NDS::DeInit() alone, so an in-game save made
# less than two seconds before quitting is silently dropped, and
# save-then-immediately-quit is exactly how people leave a game. This
# inserts the missing final flush; FlushSecondaryBuffer() writes only
# when un-flushed data is pending, so it is a no-op otherwise.
if [ "$NAME" = melonds ]; then
    perl -0pi -e 's/void retro_unload_game\(void\)\n\{\n   NDS::DeInit\(\);/void retro_unload_game(void)\n{\n   NDSCart_SRAMManager::FlushSecondaryBuffer();\n   NDS::DeInit();/' \
        "$SRC/src/libretro/libretro.cpp"
    grep -q 'FlushSecondaryBuffer();' "$SRC/src/libretro/libretro.cpp" || {
        echo "melonds unload-flush patch did not apply" >&2; exit 1; }
fi

# Mac only, and only reached when JIT_ARCH=aarch64 above put melonDS's
# ARM64 recompiler into the build. Two edits, neither of which iOS or
# tvOS ever compiles: those platforms set no JIT_ARCH, so ARMJIT.cpp and
# the whole ARMJIT_A64 directory are not in their source list at all.
if [ "$PLATFORM" = mac ] && [ "$NAME" = melonds ]; then
    # Catalyst marks pthread_jit_write_protect_np __API_UNAVAILABLE even
    # though the symbol is live in libsystem on any Apple Silicon Mac,
    # so melonDS's direct call is a hard compile error. Resolve it
    # through dlsym past the annotation, the same bypass
    # tools/build-flycast.sh uses for Flycast's three recompilers.
    perl -0pi -e '
        s/void JitEnableWrite\(\)/#if defined(__APPLE__) \&\& defined(__aarch64__)\n#include <dlfcn.h>\nstatic void cabinet_jit_write_protect(int enabled)\n{\n    typedef void (*cabinet_jitwp_t)(int);\n    static cabinet_jitwp_t fn = (cabinet_jitwp_t)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");\n    if (fn) fn(enabled);\n}\n#endif\n\nvoid JitEnableWrite()/
        unless /cabinet_jit_write_protect/;
        s/if \(__builtin_available\(macOS 11\.0, \*\)\)\n            pthread_jit_write_protect_np\(/cabinet_jit_write_protect(/g;
    ' "$SRC/src/ARMJIT.cpp"
    grep -q 'cabinet_jit_write_protect(false)' "$SRC/src/ARMJIT.cpp" || {
        echo "melonds W^X dlsym patch did not apply" >&2; exit 1; }

    # melonDS never says which CPU engine it chose, so a recompiler that
    # silently failed to get executable memory is indistinguishable from
    # one that is running. This is the core's own runtime proof, printed
    # once at JIT init: it names the buffer it actually got, or the
    # errno it failed with. Do not remove it and then claim the Mac has
    # a DS recompiler; that claim has been wrong before.
    perl -0pi -e '
        s/#include <stdlib\.h>/#include <stdlib.h>\n#include <stdio.h>\n#include <string.h>\n#include <errno.h>/
        unless /cabinet: ARM64 recompiler/;
        s/(pageAligned = \(u8\*\)mmap\(NULL, 1024\*1024\*16.*?\n)/$1        fprintf(stderr, pageAligned == MAP_FAILED\n            ? "[melonDS] cabinet: ARM64 recompiler FAILED to map JIT memory (%s)\\n"\n            : "[melonDS] cabinet: ARM64 recompiler live, 16MB MAP_JIT buffer\\n",\n            strerror(errno));\n/
        unless /cabinet: ARM64 recompiler/;
    ' "$SRC/src/ARMJIT_A64/ARMJIT_Compiler.cpp"
    grep -q 'cabinet: ARM64 recompiler live' "$SRC/src/ARMJIT_A64/ARMJIT_Compiler.cpp" || {
        echo "melonds JIT probe patch did not apply" >&2; exit 1; }

    # Fastmem's fault handler PATCHES THE JIT'S OWN CODE and never asks
    # for write permission first. That is correct where the code cache
    # is plain RWX, which is every platform melonDS's ARM64 JIT has
    # shipped on; under MAP_JIT the same pages are execute-only until
    # pthread_jit_write_protect_np says otherwise, so the first
    # unmapped-address access inside recompiled code kills the process.
    # It presents as a bus error a fraction of a second into the game,
    # with the recompiler visibly working right up to that instant:
    # SIGBUS in ARM64XEmitter::BL, called from RewriteMemAccess, called
    # from the SIGSEGV handler, called from ARMv5::ExecuteJIT.
    # Bracketing the rewrite is the whole fix, and JitEnableWrite and
    # JitEnableExecute compile to nothing off Apple, so this stays
    # correct if it is ever sent upstream.
    perl -0pi -e '
        s/        if \(rewriteToSlowPath\)\n            faultDesc\.FaultPC = ARMJIT::JITCompiler->RewriteMemAccess\(faultDesc\.FaultPC\);/        if (rewriteToSlowPath)\n        {\n            ARMJIT::JitEnableWrite();\n            faultDesc.FaultPC = ARMJIT::JITCompiler->RewriteMemAccess(faultDesc.FaultPC);\n            ARMJIT::JitEnableExecute();\n        }/
        unless /ARMJIT::JitEnableWrite\(\);/;
    ' "$SRC/src/ARMJIT_Memory.cpp"
    grep -q 'ARMJIT::JitEnableWrite();' "$SRC/src/ARMJIT_Memory.cpp" || {
        echo "melonds fastmem W^X patch did not apply" >&2; exit 1; }
fi

# Mac only, and only reached because DYNAREC=ari64 above put PCSX
# ReARMed's ARM64 recompiler into the build; iOS and tvOS compile
# new_dynarec.c not at all (no ari64, so the Makefile adds -DDRC_DISABLE
# and leaves the object out entirely).
if [ "$PLATFORM" = mac ] && [ "$NAME" = pcsx_rearmed ]; then
    # mprotect_w_x rounds the start of the range it is about to reprotect
    # down to a 4096-byte boundary. Apple Silicon pages are 16384 bytes,
    # which this same file already knows: new_dynarec_init prints
    # "pgsize 16384" three lines before the first call. mprotect demands
    # a page-aligned address, so any range starting on a 4K boundary that
    # is not also a 16K one fails with EINVAL, the code cache is left
    # execute-only, and the recompiler wedges on its next write.
    #
    # It is intermittent by nature, which makes it worse than a hard
    # failure: PCSX ReARMed logs one "mprotect(w) failed: Invalid
    # argument" and then hangs with a running emulator, a healthy log and
    # a passed dynarec self-test behind it. Seen exactly once per launch,
    # a few seconds into the BIOS.
    #
    # The end of the range is rounded up for the same reason, so the
    # length stays a whole number of real pages.
    perl -0pi -e '
        s/  u_long mstart = \(u_long\)start & ~4095ul;\n  u_long mend = \(u_long\)end;/  u_long mpsize = (u_long)sysconf(_SC_PAGESIZE);\n  if ((long)mpsize < 1) mpsize = 4096;\n  u_long mstart = (u_long)start & ~(mpsize - 1);\n  u_long mend = ((u_long)end + mpsize - 1) & ~(mpsize - 1);/
        unless /mpsize/;
    ' "$SRC/libpcsxcore/new_dynarec/new_dynarec.c"
    grep -q 'u_long mpsize = (u_long)sysconf(_SC_PAGESIZE);' "$SRC/libpcsxcore/new_dynarec/new_dynarec.c" || {
        echo "pcsx_rearmed page-size patch did not apply" >&2; exit 1; }
fi

# VeMUlator finds the loaded file's extension with strchr, the FIRST dot
# in the whole path, so any dot in a parent directory name makes every
# extension check miss and the card silently loads as nothing: no flash
# image, no write-through, a blank VMU with no error. Cabinet's own card
# path is kept dot-free on top of this, but the load must not hinge on a
# path convention a future directory rename could break. strrchr is the
# last dot, which is what "the extension" means.
if [ "$NAME" = vemulator ]; then
    sed -i '' 's/char \*ext = strchr(path/char *ext = strrchr(path/' "$SRC/main.cpp"
    grep -q 'strrchr(path' "$SRC/main.cpp" || {
        echo "vemulator strrchr patch did not apply" >&2; exit 1; }
fi

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
    CMAKE_FLAGS="-fno-common"
    if [ "$PLATFORM" = mac ]; then
        # Catalyst via CMake: a Darwin build against the macOS SDK whose
        # every compile carries the macabi target, the same rewrite the
        # Makefile cores get from the compiler shim.
        CMAKE_SYSTEM_NAME=Darwin
        CMAKE_FLAGS="-fno-common -target arm64-apple-ios18.0-macabi"
        CMAKE_EXTRA="-DCMAKE_OSX_SYSROOT=macosx"
    else
        CMAKE_EXTRA="-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0"
    fi
    cmake -S "$SRC" -B "$SPIKE/build" \
        -DCMAKE_SYSTEM_NAME=$CMAKE_SYSTEM_NAME \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        $CMAKE_EXTRA \
        -DBUILD_LIBRETRO=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF \
        -DUSE_FFMPEG=OFF -DUSE_SQLITE3=OFF -DUSE_DISCORD_RPC=OFF \
        -DUSE_EDITLINE=OFF -DUSE_ELF=OFF -DBUILD_GLES2=OFF \
        -DBUILD_GLES3=OFF -DBUILD_GL=OFF \
        -DCMAKE_C_FLAGS="$CMAKE_FLAGS" -DCMAKE_CXX_FLAGS="$CMAKE_FLAGS" \
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
    [ "$PLATFORM" = mac ] && XCRUN_SDK=macosx
    real_cc=$(xcrun -sdk "$XCRUN_SDK" -find clang)
    real_cxx=$(xcrun -sdk "$XCRUN_SDK" -find clang++)
    if [ "$PLATFORM" = mac ]; then
        # The Catalyst rewrite, on top of -fno-common: the Makefiles'
        # ios-arm64 cases bake -miphoneos-version-min and the iPhone
        # sysroot into their compile and link lines, and both must give
        # way to the macabi target and the macOS SDK. Everything else
        # passes through untouched. Bash rather than sh for the argv
        # array.
        for tool in cc clang; do
            printf '#!/bin/bash\nout=(); skip=0\nfor a in "$@"; do\n  if [[ $skip == 1 ]]; then skip=0; continue; fi\n  case "$a" in\n    -miphoneos-version-min=*) continue ;;\n    -isysroot) skip=1; continue ;;\n  esac\n  out+=("$a")\ndone\nexec "%s" -fno-common -target arm64-apple-ios18.0-macabi -isysroot "%s" "${out[@]}"\n' "$real_cc" "$SDK" > "$WRAP/$tool"
        done
        for tool in c++ clang++; do
            printf '#!/bin/bash\nout=(); skip=0\nfor a in "$@"; do\n  if [[ $skip == 1 ]]; then skip=0; continue; fi\n  case "$a" in\n    -miphoneos-version-min=*) continue ;;\n    -isysroot) skip=1; continue ;;\n  esac\n  out+=("$a")\ndone\nexec "%s" -fno-common -target arm64-apple-ios18.0-macabi -isysroot "%s" "${out[@]}"\n' "$real_cxx" "$SDK" > "$WRAP/$tool"
        done
    else
        printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cc" > "$WRAP/cc"
        printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cc" > "$WRAP/clang"
        printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cxx" > "$WRAP/c++"
        printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cxx" > "$WRAP/clang++"
    fi
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

# MINVERSION_FLAG is deliberately unquoted: the mac case's value is
# two words ("-target <triple>") that must split; the ios and tvos
# values are single words either way.
cc -arch arm64 -isysroot "$SDK" $MINVERSION_FLAG -O2 \
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
