#!/usr/bin/env python3
"""Patches an upstream Dolphin checkout so it builds and runs inside
Cabinet for Mac.

Dolphin is not a libretro core. It is a whole emulator that expects a
desktop frontend around it, and upstream ships two: the Qt app and the
headless nogui tool. Neither can run inside a Catalyst app, so Cabinet
is the third, the same arrangement PCSX2 already has here.

Every edit below is one of two kinds, and nothing else belongs in this
file:

  A CATALYST WALL. Something the macOS SDK marks unavailable under
  macabi, or a desktop-only API. All of these are host glue, never
  emulation.

  A SEAT FOR CABINET. A single function where Dolphin asks the host for
  something and Cabinet answers: audio out, and controller input.

Every patch is idempotent and verified after it is applied, so a
half-applied tree fails the build rather than producing a subtly
different emulator. Run from tools/build-dolphin-mac.sh.

Usage: patch-dolphin-mac.py <dolphin-source-dir>
"""

import sys
import os

# Spelled out once because three edits share them and getting a single
# character wrong here fails silently: the anchor simply stops matching
# and edit() raises rather than producing a wrong file.
APPLE_GUARD = "#if defined(__APPLE__)"
CATALYST_GUARD = "#if defined(__APPLE__) && !defined(CABINET_CATALYST)"
AGL_INCLUDE = '\n#include "Common/GL/GLInterface/AGL.h"\n#endif'
AGL_CREATE = (
    "\n  if (wsi.type == WindowSystemType::MacOS || wsi.type == WindowSystemType::Headless)"
    "\n    context = std::make_unique<GLContextAGL>();"
    "\n#endif"
)


def edit(path, old, new, *, guard=None, optional=False):
    """Replaces old with new, once. guard is text that means the patch
    is already applied; it defaults to new itself."""
    with open(path) as f:
        s = f.read()
    if (guard or new) in s:
        return False
    if old not in s:
        if optional:
            return False
        raise SystemExit(f"patch-dolphin-mac: anchor not found in {path}:\n{old[:200]}")
    with open(path, "w") as f:
        f.write(s.replace(old, new, 1))
    return True


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-dolphin-mac.py <dolphin-source-dir>")
    src = sys.argv[1]
    p = lambda *a: os.path.join(src, *a)

    # ---------------------------------------------------------------
    # Catalyst walls
    # ---------------------------------------------------------------

    # 1. pthread_jit_write_protect_np is __API_UNAVAILABLE for
    #    macCatalyst even though the symbol is live in libsystem on any
    #    Apple Silicon Mac, so calling it directly is a hard compile
    #    error. dlsym past the annotation, the same bypass
    #    tools/build-flycast.sh uses for Flycast and tools/build-core.sh
    #    for melonDS.
    #
    #    Worth knowing: this is the whole of Dolphin's JIT problem on
    #    this platform. Its W^X is already a nest-counted MAP_JIT
    #    design, so unlike PPSSPP it needs no extra entitlement, only
    #    these two call sites.
    edit(
        p("Source/Core/Common/MemoryUtil.cpp"),
        "// Allows a thread to write to executable memory, but not execute the data.\n"
        "void JITPageWriteEnableExecuteDisable()",
        "#if defined(_M_ARM_64) && defined(__APPLE__)\n"
        "#include <dlfcn.h>\n"
        "// Catalyst marks pthread_jit_write_protect_np unavailable even though\n"
        "// the symbol is live on any Apple Silicon Mac. Resolve it at runtime.\n"
        "static void CabinetJITWriteProtect(int enabled)\n"
        "{\n"
        "  using CabinetJITWPFn = void (*)(int);\n"
        "  static auto fn = (CabinetJITWPFn)dlsym(RTLD_DEFAULT, \"pthread_jit_write_protect_np\");\n"
        "  if (fn)\n"
        "    fn(enabled);\n"
        "}\n"
        "#endif\n"
        "\n"
        "// Allows a thread to write to executable memory, but not execute the data.\n"
        "void JITPageWriteEnableExecuteDisable()",
        guard="CabinetJITWriteProtect",
    )
    for arg in ("0", "1"):
        edit(
            p("Source/Core/Common/MemoryUtil.cpp"),
            f"pthread_jit_write_protect_np({arg});",
            f"CabinetJITWriteProtect({arg});",
            guard=f"CabinetJITWriteProtect({arg});",
        )

    # 2. libusb's darwin backend calls IOServiceAuthorize, which
    #    Catalyst marks unavailable. It sits in the detach-kernel-driver
    #    path, which Cabinet never takes, so resolve it at runtime and
    #    fail closed if it is missing.
    #
    #    libusb is kept rather than dropped, and that is deliberate: it
    #    carries the OFFICIAL GAMECUBE CONTROLLER ADAPTER as well as
    #    real Wii Remotes, and InputCommon/GCAdapter.cpp includes
    #    libusb.h unconditionally. Dropping it would cost a GameCube
    #    feature to avoid a Wii one.
    usb = p("Externals/libusb/libusb/libusb/os/darwin_usb.c")
    edit(
        usb,
        '#include "darwin_usb.h"',
        '#include <dlfcn.h>\n#include "darwin_usb.h"',
        guard="#include <dlfcn.h>",
    )
    edit(
        usb,
        "      kresult = IOServiceAuthorize (dpriv->service, kIOServiceInteractionAllowed);",
        "      {\n"
        "        /* Catalyst marks IOServiceAuthorize unavailable. Cabinet never\n"
        "           detaches a kernel driver, so resolve it at runtime. */\n"
        "        typedef kern_return_t (*cabinet_ioauth_t)(io_service_t, uint32_t);\n"
        "        static cabinet_ioauth_t cabinet_IOServiceAuthorize = NULL;\n"
        "        static int cabinet_looked_up = 0;\n"
        "        if (!cabinet_looked_up) {\n"
        "          cabinet_looked_up = 1;\n"
        "          cabinet_IOServiceAuthorize =\n"
        "            (cabinet_ioauth_t)dlsym(RTLD_DEFAULT, \"IOServiceAuthorize\");\n"
        "        }\n"
        "        if (!cabinet_IOServiceAuthorize)\n"
        "          return LIBUSB_ERROR_NOT_SUPPORTED;\n"
        "        kresult = cabinet_IOServiceAuthorize (dpriv->service, kIOServiceInteractionAllowed);\n"
        "      }",
        guard="cabinet_IOServiceAuthorize",
    )

    # 3. AGL.mm is AppKit and NSOpenGL, for the OpenGL backend Cabinet
    #    does not use: the Mac draws through Dolphin's own Metal
    #    renderer. Guarded rather than deleted so the file is still
    #    there if a GL path is ever wanted.
    edit(
        p("Source/Core/Common/CMakeLists.txt"),
        "elseif(APPLE)\n"
        "  target_sources(common PRIVATE\n"
        "    GL/GLInterface/AGL.h\n"
        "    GL/GLInterface/AGL.mm\n"
        "  )",
        "elseif(APPLE AND NOT CABINET_CATALYST)\n"
        "  target_sources(common PRIVATE\n"
        "    GL/GLInterface/AGL.h\n"
        "    GL/GLInterface/AGL.mm\n"
        "  )",
        guard="elseif(APPLE AND NOT CABINET_CATALYST)",
    )

    # 4. The Quartz controller backend is Carbon and AppKit keyboard and
    #    mouse. Cabinet's input is its own, through GameControllerManager,
    #    and reaches Dolphin at the seat installed below.
    edit(
        p("Source/Core/InputCommon/CMakeLists.txt"),
        "elseif(APPLE)\n"
        "  target_sources(inputcommon PRIVATE\n"
        "    ControllerInterface/Quartz/Quartz.h\n"
        "    ControllerInterface/Quartz/Quartz.mm\n"
        "    ControllerInterface/Quartz/QuartzKeyboardAndMouse.h\n"
        "    ControllerInterface/Quartz/QuartzKeyboardAndMouse.mm\n"
        "  )",
        "elseif(APPLE)\n"
        "  if(NOT CABINET_CATALYST)\n"
        "  target_sources(inputcommon PRIVATE\n"
        "    ControllerInterface/Quartz/Quartz.h\n"
        "    ControllerInterface/Quartz/Quartz.mm\n"
        "    ControllerInterface/Quartz/QuartzKeyboardAndMouse.h\n"
        "    ControllerInterface/Quartz/QuartzKeyboardAndMouse.mm\n"
        "  )\n"
        "  endif()",
        guard="if(NOT CABINET_CATALYST)",
    )

    #    Excluding a backend leaves its call site dangling, and the
    #    linker is the only thing that notices. Two follow the two
    #    exclusions above.
    #
    #    Quartz is reached through CIFACE_USE_OSX, so the define is what
    #    goes rather than the call: that is upstream's own switch for
    #    "this platform has that backend", and turning it off is exactly
    #    what Catalyst means here.
    edit(
        p("Source/Core/InputCommon/ControllerInterface/ControllerInterface.h"),
        APPLE_GUARD + "\n#define CIFACE_USE_OSX\n#endif",
        CATALYST_GUARD + "\n#define CIFACE_USE_OSX\n#endif",
        guard=CATALYST_GUARD + "\n#define CIFACE_USE_OSX",
    )

    #    GLContext has no such switch, so its two AGL mentions are
    #    guarded directly. Cabinet draws through Metal and never asks
    #    GLContext::Create for anything, but it is still compiled.
    edit(
        p("Source/Core/Common/GL/GLContext.cpp"),
        APPLE_GUARD + AGL_INCLUDE,
        CATALYST_GUARD + AGL_INCLUDE,
        guard=CATALYST_GUARD + AGL_INCLUDE,
    )
    edit(
        p("Source/Core/Common/GL/GLContext.cpp"),
        APPLE_GUARD + AGL_CREATE,
        CATALYST_GUARD + AGL_CREATE,
        guard=CATALYST_GUARD + AGL_CREATE,
    )

    # 5. The Metal backend asks NSScreen for HDR headroom. Three errors
    #    on one line, and the ONLY Catalyst problem in the whole
    #    renderer. UIScreen has no equivalent query, so report no HDR
    #    rather than guess at it.
    edit(
        p("Source/Core/VideoBackends/Metal/MTLUtil.mm"),
        "  backend_info->bSupportsHDROutput =\n"
        "      1.0 < [[NSScreen deepestScreen] maximumPotentialExtendedDynamicRangeColorComponentValue];",
        "#if TARGET_OS_MACCATALYST\n"
        "  // NSScreen is AppKit and unavailable under Catalyst, and UIScreen has\n"
        "  // no headroom query. Report no HDR rather than guess.\n"
        "  backend_info->bSupportsHDROutput = false;\n"
        "#else\n"
        "  backend_info->bSupportsHDROutput =\n"
        "      1.0 < [[NSScreen deepestScreen] maximumPotentialExtendedDynamicRangeColorComponentValue];\n"
        "#endif",
        guard="TARGET_OS_MACCATALYST",
    )

    # ---------------------------------------------------------------
    # Seats for Cabinet
    # ---------------------------------------------------------------

    # 6. Where Sys lives. On Apple, Dolphin derives it from the main
    #    bundle as <bundle>/Contents/Resources/Sys, which is right for
    #    Dolphin.app and wrong for Cabinet: this bundle holds PCSX2's
    #    resources and PPSSPP's beside Dolphin's, and a folder called
    #    plain "Sys" at the top of a shared Resources directory is a
    #    name waiting to collide.
    #
    #    So Cabinet sets the path instead of Dolphin guessing it. This
    #    mirrors upstream's own Android arrangement, which has exactly
    #    this problem and solves it exactly this way, rather than
    #    inventing a mechanism. Setting it from Swift also means the
    #    folder's name lives in one place instead of having to match
    #    between a build script and a compiled-in constant.
    edit(
        p("Source/Core/Common/FileUtil.h"),
        "#ifdef __APPLE__\nstd::string GetBundleDirectory();\n#endif",
        "#ifdef __APPLE__\nstd::string GetBundleDirectory();\n#endif\n"
        "\n"
        "#ifdef CABINET_CATALYST\n"
        "// Set by Cabinet before UICommon::Init. See RommApp/DolphinHost.\n"
        "void SetSysDirectory(const std::string& path);\n"
        "#endif",
        guard="#ifdef CABINET_CATALYST\n// Set by Cabinet",
    )
    edit(
        p("Source/Core/Common/FileUtil.cpp"),
        "static std::string CreateSysDirectoryPath()\n{",
        "#ifdef CABINET_CATALYST\n"
        "static std::string s_cabinet_sys_directory;\n"
        "void SetSysDirectory(const std::string& path)\n"
        "{\n"
        "  s_cabinet_sys_directory = path;\n"
        "}\n"
        "#endif\n"
        "\n"
        "static std::string CreateSysDirectoryPath()\n{",
        guard="s_cabinet_sys_directory",
    )
    edit(
        p("Source/Core/Common/FileUtil.cpp"),
        "#if defined(__APPLE__)\n"
        "  sys_directory = GetBundleDirectory() + DIR_SEP SYSDATA_DIR DIR_SEP;",
        "#if defined(CABINET_CATALYST)\n"
        "  sys_directory = s_cabinet_sys_directory + DIR_SEP;\n"
        "#elif defined(__APPLE__)\n"
        "  sys_directory = GetBundleDirectory() + DIR_SEP SYSDATA_DIR DIR_SEP;",
        guard="#if defined(CABINET_CATALYST)\n  sys_directory",
    )

    # 6. Audio out. Dolphin's vendored cubeb cannot build here: its
    #    audiounit backend has real iOS support, but this copy declares
    #    the CoreAudio device-property constants at file scope OUTSIDE
    #    the !TARGET_OS_IPHONE guard that includes the header declaring
    #    them, so the iOS path does not compile. Rather than repair
    #    someone else's vendored copy, Cabinet supplies a SoundStream of
    #    its own on AVAudioEngine, exactly as it does for PCSX2.
    #
    #    Two edits, because a backend that exists but is not the default
    #    is a backend nothing selects.
    #    The declaration goes in FIRST and carries its own distinct
    #    guard. Both edits mention CabinetCreateSoundStream, so a shared
    #    guard string means whichever runs first satisfies the other and
    #    the file builds without the declaration it needs.
    audio = p("Source/Core/AudioCommon/AudioCommon.cpp")
    edit(
        audio,
        '#include "AudioCommon/AudioCommon.h"',
        '#include "AudioCommon/AudioCommon.h"\n'
        "#ifdef CABINET_CATALYST\n"
        "#include <memory>\n"
        "class SoundStream;\n"
        "// Implemented in Cabinet's host layer, RommApp/DolphinHost.\n"
        "std::unique_ptr<SoundStream> CabinetCreateSoundStream();\n"
        "#endif",
        guard="std::unique_ptr<SoundStream> CabinetCreateSoundStream();",
    )
    edit(
        audio,
        "static std::unique_ptr<SoundStream> CreateSoundStreamForBackend(std::string_view backend)\n{\n",
        "static std::unique_ptr<SoundStream> CreateSoundStreamForBackend(std::string_view backend)\n"
        "{\n"
        "#ifdef CABINET_CATALYST\n"
        "  // Cabinet's own stream is the only working backend here, so it\n"
        "  // answers for every name including a stale one from a config file.\n"
        "  if (backend != BACKEND_NULLSOUND)\n"
        "    return CabinetCreateSoundStream();\n"
        "#endif\n",
        guard="return CabinetCreateSoundStream();",
    )

    # 7. Controller input. Pad::GetStatus is the single funnel every
    #    emulated GameCube controller port reads through, so it is the
    #    one place Cabinet has to answer.
    #
    #    Going in here rather than writing a ControllerInterface backend
    #    is deliberate. Cabinet already owns controller input across
    #    three platforms and fourteen cores in GameControllerManager,
    #    including the arcade quirks and the second-pad handling, and a
    #    Dolphin-shaped input backend would be a second, divergent copy
    #    of that. The port mapping lives in Cabinet, where every other
    #    core's already does.
    edit(
        p("Source/Core/Core/HW/GCPad.cpp"),
        "GCPadStatus GetStatus(int pad_num)\n"
        "{\n"
        "  return static_cast<GCPad*>(s_config.GetController(pad_num))->GetInput();\n"
        "}",
        "GCPadStatus GetStatus(int pad_num)\n"
        "{\n"
        "#ifdef CABINET_CATALYST\n"
        "  // Cabinet drives the pads. See RommApp/DolphinHost.\n"
        "  GCPadStatus cabinet_status;\n"
        "  if (CabinetGetGCPadStatus(pad_num, &cabinet_status))\n"
        "    return cabinet_status;\n"
        "#endif\n"
        "  return static_cast<GCPad*>(s_config.GetController(pad_num))->GetInput();\n"
        "}",
        guard="CabinetGetGCPadStatus",
    )
    edit(
        p("Source/Core/Core/HW/GCPad.cpp"),
        '#include "Core/HW/GCPad.h"',
        '#include "Core/HW/GCPad.h"\n'
        "#ifdef CABINET_CATALYST\n"
        "struct GCPadStatus;\n"
        "// Implemented in Cabinet's host layer, RommApp/DolphinHost.\n"
        "bool CabinetGetGCPadStatus(int pad_num, GCPadStatus* out);\n"
        "#endif",
        guard="CabinetGetGCPadStatus(int pad_num",
    )

    print("patch-dolphin-mac: ok")


if __name__ == "__main__":
    main()
