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

## You have to build to a real device

The simulator will not work. The emulator cores ship as static libraries built
for `arm64` iOS hardware, and they are linked unconditionally, so a simulator
build fails at the link step.

This is not only a build detail. `WKWebView`'s WebContent process carries the
dynamic code signing entitlement on real hardware, which is what lets the
WebAssembly cores in RomM's web player run with a JIT. The simulator does not
model that, so even if it linked, the thing you would be testing is not the
thing that ships.

## Two targets

**RommApp** builds Cabinet. This is the one you want.

**LayoutEditor** is a separate tool for editing the on-screen control layouts in
`RommApp/RommApp/Resources/ControlLayouts`. It is a development utility, it is
not part of the app, and it is not in the released build. You can ignore it.

## The emulator cores

The twelve native cores in `RommApp/RommApp/Native/*/lib*.a` are prebuilt and
committed, so a normal build does not compile them.

If you want to rebuild one yourself, `tools/build-core.sh` does it. It clones
the upstream libretro repository into `spikes/`, builds it for iOS, and produces
a single relocatable object whose only exported symbols are prefixed
`<prefix>_retro_*`. That prefixing matters: without it, twelve cores that each
export `retro_run` and bundle their own copy of zlib cannot link into one
binary.

```sh
tools/build-core.sh gambatte
```

Every core's upstream repository and the exact commit its library was built from
is listed in [licenses.md](licenses.md).

FinalBurn Neo and Beetle Saturn have their own scripts, `tools/build-beetle-saturn.sh`
and the FBNeo path inside `spikes/FBNeoStatic`, because they were built before
the generic script existed.

## Other tools

`tools/mame_profiles.py` builds the arcade control profile map from MAME's
listxml output. The generated `profiles.json` is committed in
`RommApp/RommApp/Resources/ArcadeProfiles` so you do not need to run it. See the
docstring if you want to regenerate it.

## Design notes

[scope-v0.1.md](scope-v0.1.md) has the full design and the reasoning behind the
decisions, including the JIT measurements that determine which systems run
natively and which run in the web player.
