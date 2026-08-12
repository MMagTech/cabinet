# Working notes for Claude

Read `docs/scope-v0.1.md` before doing anything substantial. It carries the full
design and the reasoning behind it, and most decisions in it are already settled.

## Writing conventions

- Never use `--` (a double hyphen) or an em dash. Not in prose, not in comments,
  not in commit messages, not in UI copy. Use commas, colons, or separate
  sentences.
- Plain sentences over bullet soup when explaining something.

## Git conventions

- Work on `dev`. `main` is the release branch and carries the full history.
- The old squash-merge-only rule is retired. Decided 2026-08-09, at launch: the
  history is public and complete on purpose, including the messy parts. Do not
  squash it away or propose hiding branches.
- After every build or package operation, provide a one line commit summary and a
  full commit description without being asked.
- `SECURITY.md` stays in the repository root.

## How I like to work

- Scope and mock things before writing code.
- Keep initial versions weekend sized. Ship something that works, then extend.
- Favour implementation and momentum over speculative design.
- Do not reopen settled architectural decisions without a concrete reason.
- Working software and visible progress over process overhead.

## Project shape

Native SwiftUI shell, with two ways to run a game: twelve libretro cores
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

## Things marked verify

The scope doc flags seven items as unverified. Do not build on them silently. If
a task depends on one, say so and confirm before assuming.

The instance is at `your-romm-server.example` and `/api/docs` is authoritative for
endpoint shapes. Prefer checking it over assuming RomM's API from memory.

## Do not

- Add dependencies without asking. No DI framework, no networking library, no
  architecture scaffolding. `URLSession` and Swift concurrency are enough.
- Generate the API client from `openapi.json`. That is exactly why the existing
  third party iOS client breaks across RomM versions. Six hand written calls.
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
