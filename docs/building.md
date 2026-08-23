# Building Cabinet from source

Cabinet has no package manager and no dependencies. There is nothing to install,
no `pod install`, no Swift Package resolution step. Clone it and open it.

## What you need

- macOS with **Xcode 26 or later**
- An iPhone running iOS 18 or later
- An Apple ID

Xcode 26 is not optional. Cabinet's deployment target is iOS 18, so it runs on
iOS 18 devices, but it calls a few iOS 26 APIs behind availability checks and
those still need the iOS 26 SDK to compile. On Xcode 16 the build fails on
`tabBarMinimizeBehavior` and `scrollEdgeEffectHidden`.

## Steps

1. Clone the repository and open `RommApp/RommApp.xcodeproj` in Xcode.

2. Select the **RommApp** target, go to **Signing & Capabilities**, and change
   the team to your own. The project has the maintainer's team ID committed in
   it, which will not work for you. A free Apple ID is enough.

3. Plug in your iPhone, pick it as the run destination, and build.

4. On first launch, enter your RomM server address. Cabinet shows you a short
   code, you approve it in RomM's web interface under your profile, and that is
   the pairing done. No password is ever typed into the app.

## The simulator builds, but cannot really run a game

Both app targets link and run in the Simulator: the eighteen native cores are
device-only static libraries, so they are excluded per SDK
(`EXCLUDED_SOURCE_FILE_NAMES[sdk=iphonesimulator*]` /
`[sdk=appletvsimulator*]`) rather than linked unconditionally. That is
enough for UI work, screens, layout, navigation, without a physical
device.

It is not enough to actually play anything. `NativeLauncher` throws a
friendly error rather than trying to load a core that is not there. And
`WKWebView`'s WebContent process carries the dynamic code signing
entitlement only on real hardware, which is what lets the WebAssembly
cores in RomM's web player run with a JIT. The simulator does not model
that either, so even where a core did link, the thing you would be
testing is not the thing that ships. Verifying emulation, native or web,
still needs a real device.

## Three targets

**RommApp** builds Cabinet for iOS. This is the one you want if you have an
iPhone.

**RommAppTV** builds Cabinet for tvOS, the same repository, the same `dev`
branch. Select it as the scheme instead of `RommApp`, change its team the
same way under Signing & Capabilities, and run it on an Apple TV or the
tvOS Simulator. Pairing with RomM works the same device-flow way as iOS.

**LayoutEditor** is a separate tool for editing the on-screen control layouts in
`RommApp/RommApp/Resources/ControlLayouts`. It is a development utility, it is
not part of either app, and it is not in the released build. You can ignore it.

## The emulator cores

The eighteen native cores in `RommApp/RommApp/Native/*/lib*.a` are prebuilt and
committed, so a normal build does not compile them.

If you want to rebuild one yourself, `tools/build-core.sh <core> [ios|tvos]`
does it, iOS by default. It clones the upstream libretro repository into
`spikes/`, builds it for the platform given, and produces a single
relocatable object whose only exported symbols are prefixed
`<prefix>_retro_*`. That prefixing matters: without it, eighteen cores that
each export `retro_run` and bundle their own copy of zlib cannot link into
one binary.

```sh
tools/build-core.sh gambatte tvos
```

Every core's upstream repository and the exact commit its library was built from
is listed in [licenses.md](licenses.md).

FinalBurn Neo, Beetle Saturn, Flycast and N64 have their own scripts,
`tools/build-fbneo.sh`, `tools/build-beetle-saturn.sh`,
`tools/build-flycast.sh` and `tools/build-n64.sh`, all also platform-aware.
FBNeo and Beetle Saturn predate the generic script. Flycast and N64 build
with CMake rather than a libretro Makefile, so they never fit the generic
script's table to begin with.

### Cores and tvOS

A core that works on iOS is assumed to belong on tvOS too, by default,
built with the same script and a `tvos` argument instead of `ios`. That
only actually succeeds if the core's own upstream project has a tvOS
build target in the first place, which doubles as the real "does this
even work here" check, not a blind assumption. All eighteen cores clear
that bar today.

If a core genuinely cannot make the jump, or needs real tvOS-specific
work to run well once it does, that is a legitimate outcome, not a bug,
but it needs to be a recorded one: note it here, with the reason, rather
than leaving a missing `_tvos.a` unexplained. One real precedent so far,
though it did not end up needing a platform split: a rendering
performance problem was found and fixed on tvOS (moving RGB565 decoding
from CPU to GPU, `NativePlayerRenderer.swift`), and because the fix
landed in that shared file with no platform check at all, iOS benefits
from it too, automatically. Fixing at the shared layer, when a problem
found on one platform can be, is the preferred outcome over a
platform-only patch.

No core has needed an actual platform-only exception yet. When one does,
this section is where that reasoning belongs.

On the Xcode project side: the `Native/<core>` folders hold both an
`_ios.a` and a `_tvos.a` build of a core, and the shared `NativeCore.swift`
enum has no platform awareness at all today, it assumes whatever it lists
exists everywhere. If a core is ever added that genuinely cannot exist on
one platform, that gap needs a real code-level answer, not just an absent
file, since nothing today stops the app from trying to link a binary that
was never built.

## Other tools

`tools/mame_profiles.py` builds the arcade control profile map from MAME's
listxml output. The generated `profiles.json` is committed in
`RommApp/RommApp/Resources/ArcadeProfiles` so you do not need to run it. See the
docstring if you want to regenerate it.

`tools/gen_mame2003_profiles.py` builds the second map beside it,
`mame2003-profiles.json`, from the MAME 2003-Plus reference set's own
listxml rather than a modern one. The native player reads it only while
that core is running, to answer for games the modern map has never heard
of and to drop buttons the 0.78 driver cannot read. It is committed too.
The two files layer rather than compete, and which one wins on what is
documented on `ArcadeDataSet` in `Controls/ArcadeProfiles.swift`.

## Design notes

[scope-v0.1.md](scope-v0.1.md) has the full design and the reasoning behind the
decisions, including the JIT measurements that determine which systems run
natively and which run in the web player.
