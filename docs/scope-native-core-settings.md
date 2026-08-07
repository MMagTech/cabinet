# Native core settings: shaders and core options

Status: shipped 2026-08-07, with device-tested corrections recorded in
each section below. The shader list shrank from nine to six on sight
(see The shader list), the Shader row sits below Quit rather than
above Resume, the default is labelled plain "None", and FBNeo's
options ship with source-exact values after guessed ones broke games.

Originally: proposed, not started. Decided ahead of the next native core, per
Marcus's call on 2026-08-06: get this settled once rather than retrofit it
onto a third core later.

## Why

RetroArch and, more relevantly here, RomM itself offer a real menu of
per-core tuning: shaders and core-specific options among them. This app
has never offered any of it for the native player. Two things make this
worth doing now rather than later:

- The native frontend already half-expects core options to exist.
  `LibretroFrontend.setCoreOptions:` answers a core's
  `RETRO_ENVIRONMENT_GET_VARIABLE` calls and has since the Saturn
  refactor, entirely unused because nothing in the UI ever calls it.
  Beetle Saturn has real options to expose; the original Saturn scope doc
  named "the core's own accuracy/speed options" as the lever to reach for
  if a heavier title in the wider library ever struggles where the
  go/no-go's two titles didn't.
- EmulatorJS already gives the webview player its own in-game shader
  menu. The native player has no equivalent, which reads as a step down
  from the player it is supposed to be an upgrade over.

## What ships

Two separate settings, deliberately not unified into one screen, because
they behave differently and are judged differently.

**Shaders.** In-game, not in Settings, because a shader is something you
look at to judge, not a label you read. Lives in `NativePlayerView`'s
pause menu only, `PlayerView`'s webview pause menu is untouched, since
EmulatorJS already owns shader selection on that side and nothing here
tries to unify or replace it. One row, labelled plainly "Shader", a
native SwiftUI `Menu` rather than the app's existing `.pickerStyle(.menu)`
pattern (see `coreCard`/`firmwareCard` in `GameLaunchView`): the row
itself always reads "Shader", not the current pick, and the currently
active one carries a checkmark inside the opened menu instead. The game
is already frozen on its current frame while the pause menu is up
(`NativePlayerRenderer.paused`), so picking a shader re-renders that same
frozen frame immediately behind the still-open menu, true before/after
comparison rather than a label to trust blind.

**Core options.** In Settings, not in-game, because these are abstract
toggles with nothing to visually compare. A new "Native cores" row in
Settings lists every core with a native implementation (today: FinalBurn
Neo, Beetle Saturn). Each core's own screen shows its options.

Correction, 2026-08-06, checked against real source rather than assumed:
FBNeo is not option-free. It calls `RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2`
with over 30 keys (`retro_common.cpp`), `fbneo-cpu-speed-adjust` and the
frameskip pair among them, genuinely relevant ones, alongside sixteen
`fbneo-debug-dip-*`/`fbneo-debug-layer-*` diagnostic entries that plainly
are not. FBNeo's screen needs the same hand-picked-subset treatment the
shader list already gets, not a raw dump of everything the core reports;
which keys make that cut is still an open decision, not yet made.

Deeper gap the same check surfaced: `LibretroFrontend`'s environment
callback answers `RETRO_ENVIRONMENT_GET_VARIABLE` (a core asking "what is
this key set to") but never handles `SET_CORE_OPTIONS` /
`SET_CORE_OPTIONS_V2` / `SET_VARIABLES` (a core announcing "here is my
whole option list, with choices and defaults") at all, for either core.
Beetle Saturn's options used here so far came from reading its
`libretro_core_options.h` by hand, not from the running core telling the
frontend what it has. That works, but only for the two cores someone
has actually gone and read source for, and stays correct only as long as
neither core's option set changes without a matching hand-update on this
side. Capturing `SET_CORE_OPTIONS_V2` for real, so the frontend learns a
core's options from the core itself, is worth doing before this becomes
a per-core maintenance burden, not a blocker for a first version scoped
to the two cores that exist today.

Both are stored per core, not per game: a shader or option choice applies
to every game that core runs, matching how core options are inherently
core-scoped already and keeping this from growing a per-game surface on
top of the per-game Player/Core/Firmware pickers that already exist.

## The shader list

Correction, 2026-08-07, from looking at the real Metal ports on device:
six shipped, not ten. Both ScaleHQ scalers and crt-geom looked bad
enough that Marcus dropped them on sight. What remains: None (the
default, the untouched passthrough), SABR, and the aperture, easymode,
mattias, beam and caligari CRT variants. The paragraph below records
the original selection reasoning for what the list was drawn from.

Nine, the exact set RomM/EmulatorJS already bundles (`EJS_SHADERS` in its
`shaders.js`), not independently curated: two ScaleHQ pixel scalers
(2xScaleHQ, 4xScaleHQ), SABR (edge-detecting upscaler), and five CRT
variants (aperture, easymode, geom, mattias, beam, caligari). Chosen
because it is already a proven-relevant, already-curated list, and
because someone who has used RomM's own shader picker recognizes the
same names here. A tenth, "Sharp (none)", is the default, matching what
the native player renders today.

One flat list, both cores see all nine, no per-core filtering
infrastructure yet. With exactly two native cores today, arcade and
Saturn, nothing on this list is actually wrong for either: CRT and
scaling filters both suit sprite work and 3D-era polygon output. A
genuinely single-purpose shader, a Game Boy LCD/dot-matrix grid is the
concrete example that came up, is the actual trigger for adding a
per-shader core tag; building that mechanism now, before a core exists
that would need it, is exactly the speculative complexity this project
avoids elsewhere.

Verified, 2026-08-06, against the actual `.glslp` presets in
`libretro/glsl-shaders` (the source EmulatorJS's bundle traces back to,
not the secondhand summary that first shaped this list): all nine are
single-pass, `shaders = 1`, one `shader0=` entry each. The earlier
caution about `crt-geom` commonly being multi-pass turned out to apply
to a different, more elaborate slang preset some other shader packs
ship, not this GLSL one. No intermediate render target needed for any of
the nine; every one ports as a plain fragment shader swap.

## Out of scope, explicitly

- The webview player. EmulatorJS already has its own shader menu; this
  effort does not touch it, extend it, or try to keep the two in sync.
- RetroArch's full shader system: multi-pass chains, per-pass parameters,
  shader presets. A flat picker over pre-chosen shaders, not a pipeline
  someone builds their own chain in.
- Per-shader core filtering, until a real single-purpose shader exists to
  justify it.
- Any core option beyond what a core's own `RETRO_ENVIRONMENT_GET_VARIABLE`
  calls report. No invented options, no guessing at what might be useful.
