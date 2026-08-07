# Native core settings: shaders and core options

Status: proposed, not started. Decided ahead of the next native core, per
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
Neo, Beetle Saturn). Each core's own screen shows its options, only if it
reports any: FBNeo has none today and its screen would show no options
section at all, not an empty one.

Both are stored per core, not per game: a shader or option choice applies
to every game that core runs, matching how core options are inherently
core-scoped already and keeping this from growing a per-game surface on
top of the per-game Player/Core/Firmware pickers that already exist.

## The shader list

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

Before porting any of the nine from GLSL to Metal Shading Language,
verify each one's actual pass count against real source, not the
secondhand summary that shaped this list. Single-pass ports directly;
`crt-geom` in particular is commonly multi-pass upstream in the wider
libretro-shaders ecosystem, which costs a real intermediate render
target, not just a fragment shader swap. A shader that turns out to be
multi-pass is not disqualified, just costed differently, and that cost
should be known before committing to porting all nine versus a smaller
first cut.

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
