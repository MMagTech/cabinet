#!/usr/bin/env python3
"""Takes SDL out of the PCSX2 build and puts Cabinet's input source in
its place.

PCSX2 reaches controllers and, optionally, audio through SDL3. SDL3
does not build for Mac Catalyst: its GameController backend is built on
NSViewController and its CoreAudio backend on AppKit, neither of which
Catalyst has.

Its other audio backend, the vendored cubeb, does not survive Catalyst
either, and that one is not close: 159 compile errors spread the length
of cubeb_audiounit.cpp. That file reaches for the CoreAudio device APIs
(AudioObjectPropertyAddress and the kAudioHardwareProperty constants)
which exist only on desktop macOS, and PCSX2 vendors a copy trimmed to
desktop, so its own TARGET_OS_IPHONE guards no longer cover it.

So both audio backends are out, and PS2 audio becomes Cabinet's, which
is where it already is for the other twenty-three cores. Until that
backend is written, audio resolves to PCSX2's own null stream: the
emulator runs correctly and silently, rather than pretending.

Every edit is idempotent, so running the build twice is harmless, and
every edit is small on purpose: this tree gets rebased onto the fork.

Called by tools/build-pcsx2-mac.sh. Not useful on its own.
"""

import sys
import pathlib

MARKER = "CABINET_NO_SDL"
CUBEB_MARKER = "CABINET_NO_CUBEB"


def edit(path, replacements, marker=MARKER):
    text = path.read_text()
    if marker in text:
        return False
    for old, new in replacements:
        if old not in text:
            raise SystemExit(f"{path}: could not find:\n{old}")
        text = text.replace(old, new, 1)
    path.write_text(text)
    return True


def main():
    src = pathlib.Path(sys.argv[1])
    host = pathlib.Path(sys.argv[2])

    # 1. Stop requiring SDL3 at configure time.
    edit(src / "cmake/SearchForStuff.cmake", [(
        "find_package(SDL3 3.2.6 REQUIRED)",
        "# CABINET_NO_SDL: SDL3 has no Catalyst build, see tools/patch-pcsx2-mac.py",
    )])

    # 2. Drop its sources and its link, and add Cabinet's host layer.
    edit(src / "pcsx2/CMakeLists.txt", [
        ("\tHost/CubebAudioStream.cpp\n\tHost/SDLAudioStream.cpp)",
         "\tHost/CubebAudioStream.cpp)"),
        ("\tInput/InputSource.cpp\n\tInput/SDLInputSource.cpp\n)",
         "\tInput/InputSource.cpp\n)"),
        ("\tInput/InputSource.h\n\tInput/SDLInputSource.h\n)",
         "\tInput/InputSource.h\n)"),
        ("\tSDL3::SDL3\n", ""),
    ])

    cmakelists = src / "pcsx2/CMakeLists.txt"
    text = cmakelists.read_text()
    if "CABINET_HOST_DIR" not in text:
        cmakelists.write_text(text + """
# Cabinet's own host layer, compiled straight into the core library so
# that it can reach PCSX2's internal headers.
if(DEFINED CABINET_HOST_DIR)
\ttarget_sources(PCSX2 PRIVATE
\t\t"${CABINET_HOST_DIR}/CabinetInputSource.cpp"
\t\t"${CABINET_HOST_DIR}/CabinetPS2Host.cpp"
\t\t"${CABINET_HOST_DIR}/CabinetPS2Bridge.cpp"
\t\t"${CABINET_HOST_DIR}/CabinetAudioStream.mm")
\ttarget_include_directories(PCSX2 PRIVATE "${CABINET_HOST_DIR}")

\t# The headless boot that proves the recompilers run under Catalyst
\t# before any of the app is built on top of them. Linking it is also
\t# the only way to find a host function this layer forgot: a static
\t# library resolves nothing.
\tadd_executable(cabinet-ps2-smoke "${CABINET_HOST_DIR}/CabinetPS2Smoke.cpp")
\ttarget_include_directories(cabinet-ps2-smoke PRIVATE "${CABINET_HOST_DIR}")
\ttarget_link_libraries(cabinet-ps2-smoke PRIVATE PCSX2_FLAGS PCSX2)
endif()
""")

    # 3. Audio: the SDL backend falls back to cubeb rather than failing,
    #    so a config naming SDL still gets sound.
    edit(src / "pcsx2/Host/AudioStream.cpp", [(
        "\t\tcase AudioBackend::SDL:\n"
        "\t\t\treturn CreateSDLAudioStream(sample_rate, parameters, stretch_enabled, error);",
        "\t\tcase AudioBackend::SDL:\n"
        "\t\t\t// CABINET_NO_SDL: no SDL in this build, cubeb carries audio.\n"
        "\t\t\treturn CreateCubebAudioStream(sample_rate, parameters, driver_name, device_name, stretch_enabled, error);",
    )])

    # 4. Input: Cabinet's source takes the SDL slot. It has to be filled
    #    rather than left empty, because InputManager dereferences the
    #    slot without a null check in a dozen places.
    edit(src / "pcsx2/Input/InputManager.cpp", [
        ('#include "Input/SDLInputSource.h"',
         '// CABINET_NO_SDL: Cabinet\'s input source stands in for SDL\'s.\n'
         '#include "CabinetInputSource.h"'),
        ("\tUpdateInputSourceState<SDLInputSource>(si, settings_lock, InputSourceType::SDL);",
         "\tUpdateInputSourceState<CabinetInputSource>(si, settings_lock, InputSourceType::SDL);"),
    ])

    # 5. Cubeb: out of the build entirely, and both real backends fall
    #    back to the null stream until Cabinet's own one exists.
    edit(src / "cmake/SearchForStuff.cmake", [(
        "add_subdirectory(3rdparty/cubeb EXCLUDE_FROM_ALL)",
        "# CABINET_NO_CUBEB: no Catalyst build, see tools/patch-pcsx2-mac.py",
    ), (
        "disable_compiler_warnings_for_target(cubeb)\ndisable_compiler_warnings_for_target(speex)\n",
        "",
    )], CUBEB_MARKER)

    edit(src / "pcsx2/CMakeLists.txt", [
        ("\tUSB/usb-mic/audiodev-cubeb.cpp\n", "\t# CABINET_NO_CUBEB\n"),
        ("\tUSB/usb-mic/audiodev-cubeb.h\n", ""),
        ("\tHost/AudioStream.cpp\n\tHost/CubebAudioStream.cpp)",
         "\tHost/AudioStream.cpp)  # CABINET_NO_SDL, CABINET_NO_CUBEB"),
        ("\tcubeb\n", ""),
    ], CUBEB_MARKER)

    edit(src / "pcsx2/Host/AudioStream.cpp", [
        ("\t\tcase AudioBackend::Cubeb:\n\t\t\tret = GetCubebDriverNames();\n\t\t\tbreak;",
         "\t\t// CABINET_NO_CUBEB: no backend has drivers to name."),
        ("\t\tcase AudioBackend::Cubeb:\n\t\t\tret = GetCubebOutputDevices(driver);\n\t\t\tbreak;",
         "\t\t// CABINET_NO_CUBEB: output device is Cabinet's to choose."),
        ("\t\tcase AudioBackend::Cubeb:\n"
         "\t\t\treturn CreateCubebAudioStream(sample_rate, parameters, driver_name, device_name, stretch_enabled, error);",
         "\t\tcase AudioBackend::Cubeb:"),
        ("\t\t\t// CABINET_NO_SDL: no SDL in this build, cubeb carries audio.\n"
         "\t\t\treturn CreateCubebAudioStream(sample_rate, parameters, driver_name, device_name, stretch_enabled, error);",
         "\t\t\t// CABINET_NO_SDL and CABINET_NO_CUBEB: neither of\n"
         "\t\t\t// PCSX2's own backends exists on Catalyst, so both\n"
         "\t\t\t// names resolve to Cabinet's AVAudioEngine one.\n"
         "\t\t\treturn CabinetCreateAudioStream(sample_rate, parameters, stretch_enabled, error);"),
    ], CUBEB_MARKER)

    audio_header = src / "pcsx2/Host/AudioStream.h"
    text = audio_header.read_text()
    if "CabinetCreateAudioStream" not in text:
        # Appended rather than placed near the other declarations,
        # which sit above the class this returns and cannot name it.
        audio_header.write_text(text + (
            "\n// CABINET: the audio backend that replaces SDL and cubeb.\n"
            "// Defined in RommApp/PCSX2Host/CabinetAudioStream.mm.\n"
            "std::unique_ptr<AudioStream> CabinetCreateAudioStream(\n"
            "\tu32 sample_rate, const AudioStreamParameters& parameters, bool stretch_enabled, Error* error);\n"))

    edit(src / "pcsx2/USB/usb-mic/usb-mic.cpp", [
        ('#include "USB/usb-mic/audiodev-cubeb.h"',
         "// CABINET_NO_CUBEB: the USB microphone falls back to the noop device."),
        ("\treturn std::make_unique<usb_mic::audiodev_cubeb::CubebAudioDevice>(dir, channels, std::move(devname), latency);",
         "\treturn CreateNoopDevice(dir, channels);"),
        ("\treturn usb_mic::audiodev_cubeb::CubebAudioDevice::GetDeviceList(true);", "\treturn {};"),
        ("\treturn usb_mic::audiodev_cubeb::CubebAudioDevice::GetDeviceList(false);", "\treturn {};"),
    ], CUBEB_MARKER)

    # 6. The Catalyst JIT trap, the same one Flycast hit on this target.
    #    The macOS SDK marks pthread_jit_write_protect_np
    #    __API_UNAVAILABLE for macCatalyst even though the symbol is
    #    live in libsystem on any Apple Silicon Mac, so calling it
    #    directly is a hard compile error rather than a runtime one.
    #    Reach it through dlsym past the annotation, exactly as
    #    tools/build-flycast.sh already does for the Dreamcast core.
    #
    #    Without this there is no PS2 recompiler, and the recompiler is
    #    the entire reason this integration is possible.
    edit(src / "common/Darwin/DarwinMisc.cpp", [
        ("void HostSys::BeginCodeWrite()\n{\n\tif ((s_code_write_depth++) == 0)\n"
         "\t\tpthread_jit_write_protect_np(0);\n}",
         "// CABINET_JIT_DLSYM: see tools/patch-pcsx2-mac.py\n"
         "static void CabinetJITWriteProtect(int enabled)\n{\n"
         "\ttypedef void (*cabinet_jitwp_t)(int);\n"
         "\tstatic cabinet_jitwp_t fn = (cabinet_jitwp_t)dlsym(RTLD_DEFAULT, \"pthread_jit_write_protect_np\");\n"
         "\tif (fn)\n\t\tfn(enabled);\n}\n\n"
         "void HostSys::BeginCodeWrite()\n{\n\tif ((s_code_write_depth++) == 0)\n"
         "\t\tCabinetJITWriteProtect(0);\n}"),
        ("\tif ((--s_code_write_depth) == 0)\n\t\tpthread_jit_write_protect_np(1);",
         "\tif ((--s_code_write_depth) == 0)\n\t\tCabinetJITWriteProtect(1);"),
        # Accessibility does not exist on Catalyst. The warning it
        # guarded is advisory; the event tap below reports its own
        # failure anyway.
        ("\tif (!AXIsProcessTrusted())\n\t{\n"
         "\t\tConsole.Warning(\"Process isn't trusted with accessibility permissions. "
         "Mouse tracking will not work!\");\n\t}\n\n",
         "\t// CABINET_JIT_DLSYM: AXIsProcessTrusted is macOS only.\n\n"),
    ], "CABINET_JIT_DLSYM")

    darwin = src / "common/Darwin/DarwinMisc.cpp"
    text = darwin.read_text()
    if "#include <dlfcn.h>" not in text:
        darwin.write_text(text.replace("#include <csignal>", "#include <dlfcn.h>\n#include <csignal>", 1))

    # 7. CocoaTools is AppKit from top to bottom: its own NSWindow, a
    #    CAMetalLayer on an NSView, NSScreen for the refresh rate, its
    #    own Cocoa event loop. Cabinet owns all of that, so the file is
    #    swapped for a UIKit one that answers the same header. It lives
    #    in this repo rather than as a patch because it is Cabinet's
    #    side of the seam, not a fix to the fork.
    edit(src / "common/CMakeLists.txt", [(
        "\t\tCocoaTools.mm",
        "\t\t# CABINET_COCOA: replaced, see tools/patch-pcsx2-mac.py\n"
        "\t\t\"${CABINET_HOST_DIR}/CabinetCocoaTools.mm\"",
    )], "CABINET_COCOA")

    # 8. The Metal renderer is the last AppKit holdout, and only in four
    #    places: it imports AppKit, holds an NSView, attaches its own
    #    CAMetalLayer to that view, and opens a Finder window after a
    #    GPU trace capture.
    #
    #    The layer is the part that matters. On AppKit a view is handed
    #    a layer after the fact; on UIKit a view's layer is read-only
    #    and fixed by +layerClass, so the renderer takes the layer the
    #    view already has. That is the same contract CabinetCocoaTools
    #    follows, and both must agree or they fight over the surface.
    edit(src / "pcsx2/GS/Renderers/Metal/GSDeviceMTL.h", [
        ("#include <AppKit/AppKit.h>", "#include <UIKit/UIKit.h>  // CABINET_UIKIT_VIEW"),
        ("\tMRCOwned<NSView*> m_view;", "\tMRCOwned<UIView*> m_view;"),
    ], "CABINET_UIKIT_VIEW")

    edit(src / "pcsx2/GS/Renderers/Metal/GSDeviceMTL.mm", [
        ("\tm_layer = MRCRetain([CAMetalLayer layer]);\n"
         "\t[m_layer setDrawableSize:CGSizeMake(m_window_info.surface_width, m_window_info.surface_height)];\n"
         "\t[m_layer setDevice:m_dev.dev];\n"
         "\tm_view = MRCRetain((__bridge NSView*)m_window_info.window_handle);\n"
         "\t[m_view setWantsLayer:YES];\n"
         "\t[m_view setLayer:m_layer];",
         "\t// CABINET_UIKIT_VIEW: the view owns its CAMetalLayer, set by\n"
         "\t// its +layerClass. Taking it rather than making one is what\n"
         "\t// keeps the surface tracking the view's bounds.\n"
         "\tm_view = MRCRetain((__bridge UIView*)m_window_info.window_handle);\n"
         "\t// surface_handle, when Cabinet sets it, is a layer it made\n"
         "\t// and owns. Otherwise the view's own backing layer. The two\n"
         "\t// exist side by side so they can be compared directly.\n"
         "\tCAMetalLayer* chosen = (__bridge CAMetalLayer*)m_window_info.surface_handle;\n"
         "\tm_layer = MRCRetain(chosen ? chosen : (CAMetalLayer*)[m_view layer]);\n"
         "\t[m_layer setDrawableSize:CGSizeMake(m_window_info.surface_width, m_window_info.surface_height)];\n"
         "\t[m_layer setDevice:m_dev.dev];"),
        ("\t[m_view setLayer:nullptr];\n\t[m_view setWantsLayer:NO];\n\tm_view = nullptr;",
         "\t// The layer belongs to the view and outlives the device.\n\tm_view = nullptr;"),
        ("\t\t\t\t\t[[NSWorkspace sharedWorkspace] selectFile:path\n"
         "\t\t\t\t\t                 inFileViewerRootedAtPath:@\"/tmp/\"];\n",
         "\t\t\t\t\t// CABINET_UIKIT_VIEW: NSWorkspace is AppKit. The path\n"
         "\t\t\t\t\t// is already logged above.\n"),
    ], "CABINET_UIKIT_VIEW")

    # The legacy pre-10.15 texture size probe. Its feature-set constant
    # is macOS only, and it is unreachable here anyway: the @available
    # branch above it always taken on Catalyst, and every Apple Silicon
    # GPU answers supportsFamily:MTLGPUFamilyApple3.
    edit(src / "pcsx2/GS/Renderers/Metal/GSMTLDeviceInfo.mm", [(
        "\tif ([dev supportsFeatureSet:MTLFeatureSet_macOS_GPUFamily1_v1])\n\t\treturn 16384;\n",
        "\t// CABINET_UIKIT_VIEW: macOS-only feature set, unreachable here.\n",
    )], "CABINET_UIKIT_VIEW")

    # 9. The EyeToy camera. Catalyst has AVFoundation and the Mac's own
    #    camera, but not the external-camera device type, so the
    #    built-in one is all it can enumerate. Keeping the file beats
    #    swapping in cam-noop.cpp: EyeToy games still see a camera.
    edit(src / "pcsx2/USB/usb-eyetoy/cam-macos.mm", [(
        "@[ AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeExternalUnknown ]",
        "@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]  // CABINET_NO_EXTERNAL_CAM",
    )], "CABINET_NO_EXTERNAL_CAM")

    # 10. FFmpeg, and the Homebrew leak behind it.
    #
    #     find_package(FFMPEG) locates Homebrew's copy, and that does
    #     two bad things at once. It would link native macOS dylibs
    #     into a Catalyst binary, and it puts /opt/homebrew/include on
    #     the include path AHEAD of 3rdparty/fmt/include, so every
    #     "fmt/format.h" resolved to Homebrew's fmt instead of the
    #     vendored one. That mismatch surfaced as an undefined
    #     fmt::detail::allocate and would have gone on to cause far
    #     stranger things than a link error.
    #
    #     PCSX2 already has the branch we want: with FFmpeg absent it
    #     uses its own bundled headers and loads the library at
    #     runtime. Cabinet never records video, so it simply will not
    #     find one, and video capture is the only thing that loses.
    edit(src / "cmake/SearchForStuff.cmake", [(
        "\tfind_package(FFMPEG COMPONENTS avcodec avformat avutil swresample swscale)",
        "\t# CABINET_NO_FFMPEG: see tools/patch-pcsx2-mac.py",
    )], "CABINET_NO_FFMPEG")

    # 11. The remaining SDL references, all in peripherals.
    #     usb-pad-sdl-ff is force feedback for USB racing wheels, and
    #     the DualSense LED colour reset in Pad.cpp is the other.
    edit(src / "pcsx2/CMakeLists.txt", [
        ("\tUSB/usb-pad/usb-pad-sdl-ff.cpp\n", "\t# CABINET_NO_SDL_FF\n"),
        ("\tUSB/usb-pad/usb-pad-sdl-ff.h\n", ""),
    ], "CABINET_NO_SDL_FF")

    edit(src / "pcsx2/USB/usb-pad/usb-pad.cpp", [
        ('#include "USB/usb-pad/usb-pad-sdl-ff.h"',
         "// CABINET_NO_SDL_FF: wheel force feedback needs SDL haptics."),
        ("\t\tmFFdev = SDLFFDevice::Create(mFFdevName);",
         "\t\t// CABINET_NO_SDL_FF: no force feedback device, as when\n"
         "\t\t// Create returns null on any other machine."),
    ], "CABINET_NO_SDL_FF")

    edit(src / "pcsx2/SIO/Pad/Pad.cpp", [
        ("\tSDLInputSource::ResetRGBForAllPlayers(si);",
         "\t// CABINET_NO_SDL_FF: the DualSense light bar is SDL's."),
        ('#include "Input/SDLInputSource.h"', "// CABINET_NO_SDL_FF"),
    ], "CABINET_NO_SDL_FF")

    # 12. libwebp splits its YUV conversion into a second archive that
    #     nothing declares a dependency on.
    edit(src / "common/CMakeLists.txt", [(
        "\tWebP::libwebp\n",
        "\tWebP::libwebp\n\t\"${CABINET_DEPS_DIR}/lib/libsharpyuv.a\"  # CABINET_SHARPYUV\n",
    )], "CABINET_SHARPYUV")

    # 13. PCSX2's on-screen messages. They are its frontend talking to
    #     its own users, about patches.zip and unsafe settings, in the
    #     middle of somebody else's app. There is no setting for them,
    #     so the post is dropped and the Console line kept: the
    #     information stays in the log where it is useful.
    #     There are TWO of these, AddKeyedOSDMessage and
    #     AddIconOSDMessage, each with its own copy of the same body.
    #     Guarding only the first leaves every message carrying an icon
    #     still on screen, which is most of the noisy ones. They cannot
    #     be done with two plain replacements either: the guard's own
    #     text repeats the anchor, so a second pass matches what the
    #     first just inserted. Each is placed relative to its own
    #     function instead.
    imgui = src / "pcsx2/ImGui/ImGuiManager.cpp"
    text = imgui.read_text()
    if "CabinetShowOSDMessages" not in text:
        anchor = "\tconst Common::Timer::Value current_time = Common::Timer::GetCurrentValue();"
        guard = ("\t// CABINET_NO_OSD_MESSAGES: logged above, not drawn.\n"
                 "\tif (!CabinetShowOSDMessages())\n\t\treturn;\n\n")
        for signature in ("void Host::AddKeyedOSDMessage(", "void Host::AddIconOSDMessage("):
            start = text.index(signature)
            at = text.index(anchor, start)
            text = text[:at] + guard + text[at:]
        text = text.replace(
            "void Host::AddKeyedOSDMessage(",
            "// CABINET_NO_OSD_MESSAGES: defined in CabinetPS2Host.cpp.\n"
            "bool CabinetShowOSDMessages();\n\n"
            "void Host::AddKeyedOSDMessage(", 1)
        imgui.write_text(text)

    edit(src / "pcsx2/ImGui/ImGuiManager.cpp", [(
    ), (
        "void Host::AddKeyedOSDMessage(std::string key, std::string message, float duration /* = 2.0f */)",
        "// CABINET_NO_OSD_MESSAGES: defined in CabinetPS2Host.cpp.\n"
        "bool CabinetShowOSDMessages();\n\n"
        "void Host::AddKeyedOSDMessage(std::string key, std::string message, float duration /* = 2.0f */)",
    )], "CABINET_NO_OSD_MESSAGES")

    # 14. The TV shaders, made to work at Retina output.
    #
    #     They darken alternate OUTPUT rows, which was right when
    #     output was near the PS2's own 640x448 and is invisible at
    #     2880 tall: a one-pixel-on, one-pixel-off pattern. The fix is
    #     to tie the pattern to the SOURCE resolution, which the
    #     uniform already carries, so a scanline is one source line
    #     thick however large the window is.
    #
    #     Lottes is left alone here. It is a whole CRT model rather
    #     than a two-line mask, and changing it blind is not something
    #     to do; it stays out of the menu until it can be seen.
    edit(src / "pcsx2/GS/Renderers/Metal/present.metal", [(
        "fragment float4 ps_filter_scanlines(ConvertShaderData data [[stage_in]], ConvertPSRes res)\n"
        "{\n"
        "\treturn ps_scanlines(res.sample(data.t), uint(data.p.y) % 2);\n"
        "}",
        "// CABINET_SHADER_SCALE: pattern follows the source, not the\n"
        "// output. See tools/patch-pcsx2-mac.py.\n"
        "static uint cabinet_source_row(float y, constant GSMTLPresentPSUniform& uniform)\n"
        "{\n"
        "\tfloat scale = max(1.0f, uniform.target_resolution.y * uniform.rcp_source_resolution.y);\n"
        "\treturn uint(y / scale);\n"
        "}\n"
        "\n"
        "static uint cabinet_source_col(float x, constant GSMTLPresentPSUniform& uniform)\n"
        "{\n"
        "\tfloat scale = max(1.0f, uniform.target_resolution.x * uniform.rcp_source_resolution.x);\n"
        "\treturn uint(x / scale);\n"
        "}\n"
        "\n"
        "fragment float4 ps_filter_scanlines(ConvertShaderData data [[stage_in]], ConvertPSRes res,\n"
        "\tconstant GSMTLPresentPSUniform& uniform [[buffer(GSMTLBufferIndexUniforms)]])\n"
        "{\n"
        "\treturn ps_scanlines(res.sample(data.t), cabinet_source_row(data.p.y, uniform) % 2);\n"
        "}",
    ), (
        "fragment float4 ps_filter_diagonal(ConvertShaderData data [[stage_in]], ConvertPSRes res)\n"
        "{\n"
        "\tuint4 p = uint4(data.p);\n"
        "\treturn ps_crt(res.sample(data.t), (p.x + (p.y % 3)) % 3);\n"
        "}",
        "fragment float4 ps_filter_diagonal(ConvertShaderData data [[stage_in]], ConvertPSRes res,\n"
        "\tconstant GSMTLPresentPSUniform& uniform [[buffer(GSMTLBufferIndexUniforms)]])\n"
        "{\n"
        "\tuint px = cabinet_source_col(data.p.x, uniform);\n"
        "\tuint py = cabinet_source_row(data.p.y, uniform);\n"
        "\treturn ps_crt(res.sample(data.t), (px + (py % 3)) % 3);\n"
        "}",
    ), (
        "fragment float4 ps_filter_triangular(ConvertShaderData data [[stage_in]], ConvertPSRes res)\n"
        "{\n"
        "\tuint4 p = uint4(data.p);\n"
        "\tuint val = ((p.x + ((p.y >> 1) & 1) * 3) >> 1) % 3;\n"
        "\treturn ps_crt(res.sample(data.t), val);\n"
        "}",
        "fragment float4 ps_filter_triangular(ConvertShaderData data [[stage_in]], ConvertPSRes res,\n"
        "\tconstant GSMTLPresentPSUniform& uniform [[buffer(GSMTLBufferIndexUniforms)]])\n"
        "{\n"
        "\tuint px = cabinet_source_col(data.p.x, uniform);\n"
        "\tuint py = cabinet_source_row(data.p.y, uniform);\n"
        "\tuint val = ((px + ((py >> 1) & 1) * 3) >> 1) % 3;\n"
        "\treturn ps_crt(res.sample(data.t), val);\n"
        "}",
    )], "CABINET_SHADER_SCALE")

    # Wave needs nothing: it already works in source texture space
    # rather than output pixels, which is why it is the one member of
    # the family that was correct at any window size all along.

    # 15. Present-path tracing, observation only.
    #
    #     The picture is perfect in the GS and absent on screen, and
    #     the layer has been ruled out by A/B test. This logs the whole
    #     present path so the exact divergence between a working
    #     progressive scene and a failing interlaced one can be read
    #     off rather than guessed at. Off unless CABINET_PRESENT_TRACE
    #     is set in the environment.
    edit(src / "pcsx2/GS/Renderers/Metal/GSDeviceMTL.mm", [
        ("GSDevice::PresentResult GSDeviceMTL::BeginPresent(bool frame_skip)\n{ @autoreleasepool {",
         "// CABINET_PRESENT_TRACE\n"
         "static bool CabinetTraceOn()\n{\n"
         "\tstatic const bool on = getenv(\"CABINET_PRESENT_TRACE\") != nullptr;\n"
         "\treturn on;\n}\n"
         "static u32 s_cabinet_trace_frames = 0;\n"
         "static bool CabinetTraceThisFrame()\n{\n"
         "\treturn CabinetTraceOn() && (s_cabinet_trace_frames < 8 || (s_cabinet_trace_frames % 120) == 0);\n}\n\n"
         "GSDevice::PresentResult GSDeviceMTL::BeginPresent(bool frame_skip)\n{ @autoreleasepool {"),
        ("\tif (frame_skip || m_window_info.type == WindowInfo::Type::Surfaceless || !g_gs_device)\n"
         "\t{\n"
         "\t\tImGui::EndFrame();\n"
         "\t\treturn PresentResult::FrameSkipped;\n"
         "\t}",
         "\tif (CabinetTraceThisFrame())\n"
         "\t\tConsole.WriteLnFmt(\"[TRACE] BeginPresent frame={} skip={} surfaceless={} layer={} drawable_size={}x{}\",\n"
         "\t\t\ts_cabinet_trace_frames, frame_skip,\n"
         "\t\t\tm_window_info.type == WindowInfo::Type::Surfaceless, m_layer != nullptr,\n"
         "\t\t\tm_layer ? (u32)[m_layer drawableSize].width : 0u,\n"
         "\t\t\tm_layer ? (u32)[m_layer drawableSize].height : 0u);\n"
         "\tif (frame_skip || m_window_info.type == WindowInfo::Type::Surfaceless || !g_gs_device)\n"
         "\t{\n"
         "\t\tif (CabinetTraceThisFrame())\n"
         "\t\t\tConsole.WriteLn(\"[TRACE]   -> FrameSkipped at entry\");\n"
         "\t\ts_cabinet_trace_frames++;\n"
         "\t\tImGui::EndFrame();\n"
         "\t\treturn PresentResult::FrameSkipped;\n"
         "\t}"),
        ("\tif (!m_current_drawable)\n"
         "\t{\n"
         "\t\t[buf pushDebugGroup:@\"Present Skipped\"];",
         "\tif (CabinetTraceThisFrame())\n"
         "\t\tConsole.WriteLnFmt(\"[TRACE]   nextDrawable {}\", m_current_drawable ? \"ok\" : \"NULL\");\n"
         "\tif (!m_current_drawable)\n"
         "\t{\n"
         "\t\ts_cabinet_trace_frames++;\n"
         "\t\t[buf pushDebugGroup:@\"Present Skipped\"];"),
        ("void GSDeviceMTL::PresentRect(GSTexture* sTex, const GSVector4& sRect, GSTexture* dTex, const GSVector4& dRect, PresentShader shader, float shaderTime, Filter filter)\n{ @autoreleasepool {",
         "void GSDeviceMTL::PresentRect(GSTexture* sTex, const GSVector4& sRect, GSTexture* dTex, const GSVector4& dRect, PresentShader shader, float shaderTime, Filter filter)\n{ @autoreleasepool {\n"
         "\tif (CabinetTraceThisFrame())\n"
         "\t\tConsole.WriteLnFmt(\"[TRACE]   PresentRect src={}x{} dTex={} sRect=({},{},{},{}) dRect=({},{},{},{}) shader={}\",\n"
         "\t\t\tsTex ? sTex->GetWidth() : -1, sTex ? sTex->GetHeight() : -1, dTex != nullptr,\n"
         "\t\t\tsRect.x, sRect.y, sRect.z, sRect.w, dRect.x, dRect.y, dRect.z, dRect.w,\n"
         "\t\t\tstatic_cast<int>(shader));"),
        ("\t\tif (use_present_drawable)\n\t\t\t[m_current_render_cmdbuf presentDrawable:m_current_drawable];",
         "\t\tif (CabinetTraceThisFrame())\n"
         "\t\t\tConsole.WriteLnFmt(\"[TRACE]   EndPresent use_present_drawable={} vsync={}\",\n"
         "\t\t\t\tuse_present_drawable, static_cast<int>(m_vsync_mode));\n"
         "\t\tif (use_present_drawable)\n\t\t\t[m_current_render_cmdbuf presentDrawable:m_current_drawable];"),
        ("\tFlushEncoders();\n\tFrameCompleted();\n\tm_current_drawable = nullptr;",
         "\tFlushEncoders();\n\tFrameCompleted();\n\ts_cabinet_trace_frames++;\n\tm_current_drawable = nullptr;"),
    ], "CABINET_PRESENT_TRACE")

    # 16. The present guard itself. PresentRect is never reached on the
    #     failing games, and its guard is `current && !blank_frame`,
    #     where blank_frame is !Merge(field). This says which one.
    edit(src / "pcsx2/GS/Renderers/Common/GSRenderer.cpp", [(
        "\tconst bool blank_frame = !Merge(field);",
        "\tconst bool blank_frame = !Merge(field);\n"
        "\t// CABINET_MERGE_TRACE\n"
        "\tif (getenv(\"CABINET_PRESENT_TRACE\"))\n"
        "\t{\n"
        "\t\tstatic u32 n = 0;\n"
        "\t\tif (n < 8 || (n % 120) == 0)\n"
        "\t\t{\n"
        "\t\t\tGSTexture* cur = g_gs_device->GetCurrent();\n"
        "\t\t\tfprintf(stderr, \"[TRACE] Merge field=%d blank_frame=%d current=%d size=%dx%d\\n\",\n"
        "\t\t\t\t(int)field, (int)blank_frame, cur != nullptr ? 1 : 0,\n"
        "\t\t\t\tcur ? cur->GetWidth() : -1, cur ? cur->GetHeight() : -1);\n"
        "\t\t}\n"
        "\t\tn++;\n"
        "\t}",
    )], "CABINET_MERGE_TRACE")

    # 17. The final drawable itself. Everything upstream of the present
    #     pass has been proven correct; this reads the CAMetalDrawable
    #     after the GPU completes, logs the command buffer's status and
    #     error, and dumps the pixels. See CabinetDrawableProbe.h. Off
    #     unless CABINET_DRAWABLE_PROBE is set. Temporary.
    edit(src / "pcsx2/CMakeLists.txt", [(
        "\t\t\"${CABINET_HOST_DIR}/CabinetAudioStream.mm\")",
        "\t\t\"${CABINET_HOST_DIR}/CabinetAudioStream.mm\"\n"
        "\t\t\"${CABINET_HOST_DIR}/CabinetDrawableProbe.mm\")\n"
        "\t# CABINET_DRAWABLE_PROBE\n"
        "\tset_source_files_properties(\"${CABINET_HOST_DIR}/CabinetDrawableProbe.mm\" PROPERTIES COMPILE_OPTIONS -fobjc-arc)",
    )], "CABINET_DRAWABLE_PROBE")
    edit(src / "pcsx2/GS/Renderers/Metal/GSDeviceMTL.mm", [
        ('#include "GSMTLSharedHeader.h"',
         '#include "GSMTLSharedHeader.h"\n'
         '#include "CabinetDrawableProbe.h" // CABINET_DRAWABLE_PROBE'),
        ("\t[m_layer setDevice:m_dev.dev];\n}",
         "\t[m_layer setDevice:m_dev.dev];\n"
         "\tCabinetProbeConfigureLayer(m_layer, m_view);\n}"),
        ("\tEndRenderPass();\n\tif (m_current_drawable)\n\t{\n\t\tconst bool use_present_drawable",
         "\tEndRenderPass();\n"
         "\tCabinetProbePresent(m_current_render_cmdbuf, m_current_drawable, m_layer, m_dev.dev);\n"
         "\tif (m_current_drawable)\n\t{\n\t\tconst bool use_present_drawable"),
        ("\t[m_current_render_cmdbuf commit];\n\tm_current_render_cmdbuf = nil;",
         "\tCabinetProbeCommandBuffer(m_current_render_cmdbuf);\n"
         "\t[m_current_render_cmdbuf commit];\n\tm_current_render_cmdbuf = nil;"),
    ], "CABINET_DRAWABLE_PROBE")

    print(f"patched {src} for Catalyst, host layer at {host}")


if __name__ == "__main__":
    main()
