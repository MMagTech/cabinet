# The Mac Dreamcast lab

Runs Cabinet's Flycast core headless on this Mac, on ANGLE's GLES-on-
Metal stack (the same GLES dialect the devices speak), at a calibrated
device speed, with the interpreter profiler streaming. Built 2026-08-18
after a week of every measurement costing a device round-trip; see
memory `flycast-perf-investigation` for the investigation it closes.

## One-time setup

1. ANGLE (about 30 minutes, mostly downloads):

       git clone https://chromium.googlesource.com/chromium/tools/depot_tools
       export PATH="$PWD/depot_tools:$PATH"
       depot_tools/ensure_bootstrap        # or gn later fails on python3_bin_reldir
       git clone --depth 1 https://chromium.googlesource.com/angle/angle
       cd angle && python3 scripts/bootstrap.py && gclient sync -j8
       gn gen out/mac --args='is_debug=false target_os="mac" angle_enable_metal=true angle_enable_vulkan=false angle_enable_gl=false'
       autoninja -C out/mac libEGL libGLESv2

2. The core, from the spikes tree (which must carry the rglgen patch,
   see below):

       cmake -B build-lab -DLIBRETRO=ON -DUSE_GLES=ON \
         -DCMAKE_BUILD_TYPE=RelWithDebInfo \
         -DCMAKE_C_FLAGS="-isystem <angle>/include -DCABINET_MAC_ANGLE -DTARGET_NO_REC -DCABINET_PROFILER" \
         -DCMAKE_CXX_FLAGS="-isystem <angle>/include -DCABINET_MAC_ANGLE -DTARGET_NO_REC -DCABINET_PROFILER"
       cmake --build build-lab -j8

   CABINET_PROFILER compiles in the per-timeslice profiler, the
   calibration loop, the device-speed throttle, the instruction-mix
   counters and the CAB_PD_NOCHECK ablation switch. Device builds via
   tools/build-flycast.sh never define it, so the shipping cores carry
   none of that; define it here or the lab has no instruments.

   TARGET_NO_REC must be a COMPILE FLAG, not a cmake -D option; as an
   option it is silently ignored and you get the dynarec. The tell: the
   interpreter writes ~/Library/Caches/flycast-profile.txt, the dynarec
   does not. Check for that file before trusting any CPU numbers.

3. The harness:

       clang -O2 -Wl,-headerpad_max_install_names \
         -I <angle>/include -I <spikes>/core/deps/libretro-common/include \
         dclab.c -o dclab -L <angle>/out/mac -lEGL -lGLESv2 \
         -Wl,-rpath,<angle>/out/mac
       install_name_tool -change ./libEGL.dylib <angle>/out/mac/libEGL.dylib \
         -change ./libGLESv2.dylib <angle>/out/mac/libGLESv2.dylib dclab

## Running

    ANGLE_EGL=<angle>/out/mac/libEGL.dylib \
    ANGLE_GLES=<angle>/out/mac/libGLESv2.dylib \
    CABINET_TARGET_NS_PER_INSTR=7.7 \
    ./dclab flycast_libretro.dylib game.chd sysdir [frames]

CABINET_TARGET_NS_PER_INSTR picks the device being modelled, using the
measured per-instruction interpreter cost of real hardware: 7.7 is an
Apple TV (A15) in light scenes, 10.5 an A15 in heavy scenes, 4.9 an
iPhone Air; unset runs the M4 flat out (~2.4x realtime). The throttle
self-verifies: the profiler's own ns_per_instr column should read the
target.

BIOS and ROMs pull from a device cache when the RomM host doesn't
resolve:

    xcrun devicectl device copy from --device <id> \
      --domain-type appDataContainer --domain-identifier com.mmagtech.CabinetDev.tv \
      --source "Library/Caches/native-rom-cache/<romid>/dc/dc_boot.bin" ...

## Device-run toggles and traps

The cores read a few environment switches, injectable per launch with
`devicectl device process launch -e '{"KEY":"value"}'`: CAB_PREDECODE
(0 disables the predecoded-block interpreter), CAB_PD_FASTMEM (0
disables the fast memory-handler variants), CAB_SH4CLOCK (overrides the
sh4clock option for headless clock sweeps), and, in profiler builds
only, CAB_PD_NOCHECK (skips the block entry check; hangs real games at
the first code reload, measurement use only). The dclab harness also
answers any core option from a CAB_OPT_<key> environment variable.

Two traps when pulling results off a device: a stalled launch leaves
the previous run's full-size trace in place, so guard every pull with
an md5 compare against the previous pull, never a size check; and a
hung game leaves the app foreground where the next launch can fail to
displace it, so treat identical pulls from different configs as
contamination, not data.

## The rglgen patch

libretro-common's `include/glsym/rglgen_headers.h` checks `__APPLE__`
before `HAVE_OPENGLES3`, so Apple always gets desktop GL headers; it
predates GLES existing on Macs. The spikes tree carries a 7-line branch
gated on CABINET_MAC_ANGLE that includes ANGLE's GLES3 headers first.
A fresh spikes checkout needs it reapplied; the patch is in
`rglgen-mac-angle.patch` next to this file.

## What transfers and what does not

CPU/interpreter numbers: transfer (validated: the menu workload's
mem_pct=56.9 fingerprint matches the Apple TV's exactly). Renderer-level
GLES behaviour: transfers in dialect, not in driver. Present/display
latency and thermals: device-only, the lab cannot see them.

Measured here 2026-08-18: glReadPixels 640x480 RGBA under ANGLE 0.7-1.2ms
against the A15's 4.4ms Apple-GLES floor, the first hard evidence that
floor is driver, not physics.
