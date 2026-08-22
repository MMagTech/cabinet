# Working notes for Claude

This file describes Cabinet: its architecture, its conventions, its history,
and the technical findings that cost real time to learn. Anything a
contributor who has never met the author could not act on, or that would be
just as true on a different project, does not belong here.

Read `docs/scope-v0.1.md` before doing anything substantial. It carries the full
design and the reasoning behind it, and most decisions in it are already settled.

## Writing conventions

- Never use `--` (a double hyphen) or an em dash. Not in prose, not in comments,
  not in commit messages, not in UI copy. Use commas, colons, or separate
  sentences.
- Plain sentences over bullet soup in comments and documentation.

## Git conventions

- Work on `dev`. Both platforms live there, iOS and tvOS. `main` is the release
  branch and carries the full history. The old separate `tvos` branch is
  retired, merged into `main` on 2026-08-12. Do not recreate it.
- Releases are per platform, tagged independently on `main`: `ios-v0.x.x-alpha`
  and `tvos-v0.x.x-alpha`, titled "Cabinet for iOS 0.x.x-alpha" and
  "Cabinet for tvOS 0.x.x-alpha". The two platforms do not have to release
  together or share version numbers. The two oldest iOS tags (`v0.1.0-alpha`
  and `v0.2.0-alpha`) predate this convention and keep their names.
- To cut a release, in order: first set the target's `MARKETING_VERSION` in
  the project to match the tag being cut, and bump `CURRENT_PROJECT_VERSION`
  if the build will also go to TestFlight (Apple requires a unique build
  number per upload). Verify the project version matches the tag before
  tagging; the iOS 0.2.0-alpha release shipped reporting "0.1" because this
  step was skipped. Then archive the scheme (`RommApp` for iOS, `RommAppTV`
  for tvOS) with `xcodebuild archive` and `CODE_SIGNING_ALLOWED=NO`, copy
  the built `.app` into a `Payload/` folder and zip it as an unsigned
  `.ipa`, then `gh release create` with the tag and `gh release upload` the
  IPA.
- The old squash-merge-only rule is retired. Decided 2026-08-09, at launch: the
  history is public and complete on purpose, including the messy parts. Do not
  squash it away or propose hiding branches.
- A fix on one branch and a refactor that moves the same code on another
  branch merge cleanly and silently drop the fix. There is no conflict and
  nothing in the diff to see. It cost the native player's stereo audio for
  five days: `72f8a4e` fixed it in `NativePlayerView.swift`, the tvOS
  branch had already moved that code to `NativePlayerAudio.swift`, and the
  merge in `263bdf0` kept the move and dropped the fix (found 2026-08-16).
  After merging any branch that has diverged for more than a day, list what
  the merged-in side changed and confirm each change still exists where
  that code now lives.
- `SECURITY.md` stays in the repository root.

## Project shape

Native SwiftUI shell, with two ways to run a game: eighteen libretro cores
compiled into the app, and a `WKWebView` player running RomM's EmulatorJS page
for everything else.

The JIT boundary decides which is which. WKWebView's WebContent process carries
the dynamic code signing entitlement so WASM cores get a real JIT, while cores
compiled into the app process are interpreter only. Systems whose cores need a
dynamic recompiler to hit full speed, N64 and anything heavier, stay on the
webview. Systems an interpreter can carry run natively, which buys real
fullscreen, native input and offline play. That split is settled; do not
propose moving a dynarec-dependent system into the app process.

Home is resume first, not a library grid. One tap back into the last game.

iOS's one ambient, content-derived background lives on the game launch
screen, the game's own cover blurred behind it, the same contained way
Music treats Now Playing. Do not spread that into iOS's app-shell chrome,
lists, tab bar, settings; that reads as skinning rather than the
platform's own idiom, and tvOS already owns the always-ambient shell
version of this idea. Decided deliberately, not a gap to fill in later.

## Platform boundaries

- tvOS code lives in `RommApp/RommAppTV/`. iOS and shared code live in
  `RommApp/RommApp/`. During tvOS work, do not edit iOS or shared files
  without calling it out explicitly first. The reverse applies to iOS work.
- When tvOS needs logic that lives in an iOS-only file, extract it to a
  shared file both targets compile. Never copy-paste it into the tvOS target.
  That direction, iOS holding the shared logic tvOS reaches into, is about
  implementation history, iOS existed as a full app first. It is not a
  design rule; see below for that.
- iOS and tvOS do not have feature parity. Do not assume a feature exists on
  one platform because it exists on the other. Check the file's own doc
  comments first.
- iOS and tvOS should not drift into looking or feeling like separate
  products. Feature parity is not required and screens routinely diverge
  for real platform reasons, tvOS has no touch controls, iOS has no
  controller-driven focus navigation. The two apps' visual and experiential
  identity, materials, color, ambient treatment, the sense of being one app
  on two platforms, is meant to stay recognizable over time. A UI or UX
  idea on either platform can inspire a version of it on the other, in that
  platform's own idiom; this is not a requirement to mirror every change,
  just an awareness to keep the two from quietly drifting apart. When a
  change on either platform genuinely risks that, raise it explicitly.
  The choice may need to be actually defended, not just explained and
  accepted at face value, rather than deciding quietly either way.
- Any change to a persisted local data format needs a non-destructive
  migration path decided at the same time, not discovered as data loss later.
- A native core that works on iOS is assumed to belong on tvOS too, by
  default. tvOS not getting one needs a real reason, a spike test or an
  actual finding, not silence. This is a fixed direction on purpose,
  unlike the UI/UX rule above; cores start on iOS and tvOS inherits.
  Details, and where to record an exception or platform-specific tuning,
  live in `docs/building.md`.

## Blast radius: say it out loud before touching shared code

Fourteen cores and two platforms run through a handful of shared files.
`LibretroFrontend`, `NativePlayerRenderer`, `NativePlayerAudio`,
`GameControllerManager` and the control layouts are the main ones. A fix
aimed at one core lands on all of them unless it is deliberately scoped.

- **State the two lists before building.** Which cores and platforms
  actually execute the lines being changed, and which ones the change is
  meant to help. If those lists differ, say so explicitly, in those
  words, and get agreement before writing code. Do not decide alone that
  the difference is harmless.
- **Prefer additive.** A new enum case, a new flag defaulting to today's
  behaviour, a new branch. Never edit an existing shared branch when an
  additive change would do, so untouched cores run byte-identical code.
- **Scope the fix as narrowly as the evidence.** A finding measured on
  one core belongs behind a check for that core, in the frontend where
  core identity already lives, not in the shared path "because it should
  be harmless everywhere".
- **Test the blast radius, not the target.** Before calling it done, run
  a game on at least one core per affected class, not only the core that
  motivated the work. For the render path that means one core per pixel
  format plus both hardware-rendered cores.

Two regressions on 2026-08-16 are why this section exists, both from
Dreamcast fixes placed in shared code, and both found on real hardware
after the work was called done: an audio governor built for
Flycast's free-running emulation thread went into the shared draw loop
and slowed N64 down, and a teardown condition widened for Flycast went
into the shared load path and turned an N64 relaunch into a crash in
GLideN64's `TexrectDrawer::destroy`. Both were one-line widenings that
looked harmless. Neither was.

## Things that are settled

- Auth is RomM's device authorization flow. Not username and password, not
  cookie sharing, not a pasted token.
- Save states are slot based because that is what RomM's asset model stores.
- Control layouts are data, not code. One file per system or profile, trait keyed.
- Arcade control profiles resolve through a chain, not a lookup. See the doc.
- Touch input copies DeltaCore's approach: extended hit frames, overlapping d-pad
  rects, continuous d-pad reporting. Read their approach, do not copy their code.
  Delta is AGPLv3 and this project is MIT.
- Physical controllers are captured natively with `GameController`, not the
  webview's Gamepad API.
- FBNeo must never be answered on the left analog axis. Its own input code
  has a fake-analog fallback that reads that axis even for digital joystick
  games and ORs it into the digital directions, and the physical-controller
  path's y sign is opposite libretro's convention there, so feeding it makes
  a Bluetooth pad register up and down in the same frame (issue #3, fixed
  2026-08-15 in `LibretroFrontend.mm`'s `inputState`). Arcade sticks are
  fully covered by the digital bits. Do not "clean up" that gate, and do not
  add a new path that writes the analog-left values while FBNeo is running.
- Any change touching controller input (GameControllerManager, inputState,
  the send/sendStick wiring) must be verified on a real device with a real
  Bluetooth pad on a twin-stick arcade game (Smash TV) before it is called
  done. A commit once claimed exactly this verification while introducing
  exactly this bug; the touch overlay and the menus exercising fine proves
  nothing about the pad path.

## Things marked verify

The scope doc's Open items list flags what is still unverified; most of the
original seven are resolved now, check the list itself rather than trusting a
count here, it will only go stale again. Do not build on a remaining item
silently. If a task depends on one, say so and confirm before assuming.

The instance is at `your-romm-server.example` and `/api/docs` is authoritative for
endpoint shapes. Prefer checking it over assuming RomM's API from memory.
RomM has no dedicated API version and ships fast with no changelog; see
`docs/checking-romm-compatibility.md` before assuming a new RomM release
did not change something Cabinet depends on.

## Do not

- Add dependencies. No DI framework, no networking library, no architecture
  scaffolding. `URLSession` and Swift concurrency are enough, and that is a
  settled decision rather than a default to revisit. Raise it as a proposal
  first if something genuinely cannot be done without one.
- Generate the API client from `openapi.json`. That is exactly why the existing
  third party iOS client breaks across RomM versions. Hand written calls, not
  generated.
- Commit `tools/*.xml` or `tools/profiles.json`. Derived data, regenerate it.

## tvOS conventions

This applies to tvOS work only; none of it changes anything about iOS.

- Never give a focusable `Button` on tvOS `.buttonStyle(.plain)` or
  `.buttonStyle(.card)`, even for a row that looks unstyled without one.
  Both paint a real system focus effect (`.plain` included, not just `.card`)
  that overrides or sits on top of any custom `.background` the row already
  has, and neither reserves headroom for its own focus-scale growth, so a
  focused row can grow into its neighbour. Use one of this project's own
  `ButtonStyle`s from `TVCoverFocus.swift` (`CoverFocusStyle` for cover art,
  `TextFocusStyle` for a short text link or pill, `RowFocusStyle` for a
  full-width settings-style row) or a new one built the same way, never a
  bare system style.
- Never use `.navigationTitle` on tvOS. It paints over content instead of
  reserving space above it. Put the title as a plain `Text` inside the
  screen's own scroll content instead, the pattern every existing tvOS
  screen already uses.
