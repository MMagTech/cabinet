# Working notes for Claude

Read `docs/scope-v0.1.md` before doing anything substantial. It carries the full
design and the reasoning behind it, and most decisions in it are already settled.

## Writing conventions

- Never use `--` (a double hyphen) or an em dash. Not in prose, not in comments,
  not in commit messages, not in UI copy. Use commas, colons, or separate
  sentences.
- Plain sentences over bullet soup when explaining something.

## Git conventions

- Work on `dev`. `main` gets squash merges only.
- Before merging `dev` to `main`, stop and walk me through the squash merge step
  by step before running anything. Raw dev commit messages have leaked into a
  public main history before and I do not want that repeated.
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

Native SwiftUI shell, `WKWebView` player running RomM's EmulatorJS page.

The app never emulates natively. WKWebView's WebContent process carries the
dynamic code signing entitlement so WASM cores get a real JIT, while the same
cores compiled into the app process would be interpreter only. This is the
load bearing architectural decision. Do not propose vendoring native cores.

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
