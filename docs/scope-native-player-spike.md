# Native player spike, scope

Status: proposed, not started. This amends the "never emulate natively"
decision in scope-v0.1.md, which required a concrete reason to reopen.
The reason exists and is measured: iOS's embedded webview leaks
graphics memory for certain games (Neo Geo, CV1000 under fbneo) until
the OS kills the web process at its hard 2GB cap, roughly one minute of
continuous play. Every reachable lever was tested on device and ruled
out; Apple Feedback is filed. The original decision's logic was that
WASM cores in the app process would be interpreter-only without JIT.
That logic still holds for WASM, and still rules out dynarec-dependent
systems. It never applied to natively compiled cores for 2D-era
systems, which need no JIT at all. The decision is therefore narrowed,
not reversed: the webview player remains the default; a native player
exists for platforms where the webview measurably cannot deliver
Safari-class play.

## What the spike proves

One sentence: Metal Slug boots from RomM into a natively compiled FBNeo
core and plays at full speed with Cabinet's existing controls.

That single sentence carries every risk worth testing: the core builds
for iOS, the libretro frontend plumbing works, video and audio hold 60,
and the existing input layer drives it. Everything else is deliberately
out.

## In scope

- FBNeo built as a static library for iOS (arm64 device only, no
  simulator support needed for the spike).
- A minimal libretro frontend, one file if possible:
  - retro_run loop on a display link.
  - Video: core framebuffer (RGB565/XRGB8888) into a Metal-backed
    layer, aspect-fit, no shaders, no filters.
  - Audio: core's audio batch into a CoreAudio/AVAudioEngine ring
    buffer, mono-or-stereo passthrough.
  - Input: GameControllerManager and TouchControlPad already emit
    RetroPad ids; wire them straight into retro_set_input_state. No
    remap UI changes.
- ROM delivery: reuse the existing romContentRequest download path to
  fetch the zip into memory or a temp file and hand it to the core.
  Neo Geo BIOS (neogeo.zip) fetched the same way via the existing
  firmware request.
- Entry point: a hidden Debug-screen button, "Play natively (spike)",
  hardcoded to the test game. The launch screen, resume flow, and
  webview player are untouched.

## Out of scope, explicitly

- Save states in either direction (RomM upload or local). The spike
  may lose progress on exit; that is fine.
- Every platform except arcade/fbneo, and every game except the one
  test title.
- Pause menu, boot curtain, crash recovery, autosave: none apply, the
  native path has no web process to lose.
- Core options UI, shaders, per-game settings.
- App Store review questions. Sideload/TestFlight context only for
  now; emulators are permitted since 2024 but that gets its own pass
  later.

## Success and failure criteria

Success: the test game reaches gameplay, holds a steady frame rate at
audible-clean audio for ten continuous minutes (ten times the webview's
ceiling), and responds to both touch and physical controller input.

Failure worth respecting: if the frontend plumbing balloons past
roughly a weekend of effort before video-plus-audio-plus-input works,
stop and reassess rather than grind. The webview player still works
today at one-minute intervals; the native path must earn its keep
quickly or wait.

## What full integration would add later, listed so nobody scopes it
into the spike by accident

- Save states through RomM's assets API with the same naming the
  webview player uses, so both players share saves.
- Launch-screen routing: per-platform or per-game choice between
  players, defaulting native where the webview is known to leak,
  webview elsewhere. The compatibility crash counter already knows
  which games those are.
- The remaining 2D cores where native is strictly better, one at a
  time, each with its own go/no-go.
- Licensing text in Settings: FBNeo's non-commercial license alongside
  the app's MIT license, per-core attribution. The app remains free,
  which satisfies FBNeo's terms; this still gets written down visibly.
- An honest look at whether the webview player retires for some
  platforms entirely, decided only after the native path has months of
  real use.
