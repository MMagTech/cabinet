# RomM iOS Client, v0.1 Scope (revised)

Supersedes the first draft. Every decision below is grounded in RomM's source
unless marked **verify**.

**Shape:** native shell, webview player, resume-first.
**Budget:** two to three weekends.

---

## What this app is for

Fixing three things the browser cannot do:

1. True fullscreen. Safari on iPhone has no Fullscreen API for arbitrary elements,
   which is why RomM ships an iOS pseudo-fullscreen shim. A WKWebView has no
   browser chrome to hide.
2. Touch controls that feel right, plus proper physical controller support.
3. One-tap resume of whatever you were last playing.

Everything else is parity with the web UI and is not a reason to build anything.

---

## Architecture

```
RommApp
├── RommClient (actor)      REST, device auth, Keychain
├── Home                    resume-first launch screen
├── Library                 grid / compact list, per-platform preference
├── PlayerHost              WKWebView + native control overlay
├── ControlEngine           profiles, layouts, touch and GameController input
└── ProfileStore            MAME-derived control profile map (bundled)
```

The app never emulates natively. EmulatorJS runs in the webview every time.

**Why webview:** WKWebView's WebContent process carries the dynamic-code-signing
entitlement, so WASM cores get JIT. Native cores in the app process do not and
run interpreted.

**Verified** on 2026-08-01, iPhone Air (iPhone18,4) on iOS 26.6, Release build.
An identical integer loop run three ways in one app: WASM in a `WKWebView`
reached 405 to 422 million iterations per second against 433 to 508 for the
same loop in native Swift, a ratio of 0.83 to 0.95 across four runs, with
checksums matching. Interpreted execution would be roughly an order of
magnitude below native, so WASM is being jitted and this decision holds.
Reproduce with `spikes/JITProbe`.

---

## Auth

RomM has a purpose-built third-party client flow. Use it. No password entry, no
token pasting, no cookie scraping.

1. `POST /api/auth/device/init`. Required: `client_device_identifier`, `name`,
   `client`, `requested_scopes`. Optional: `platform`, `client_version`, both
   capped at 50 characters. Returns a device code and a short user code.
2. Show the user code. Approve in the RomM web UI.
3. Poll `POST /api/auth/device/token` until issued.

**Scopes to request** (fixed at pair time, adding one later means re-pairing):

- `me.read`
- `roms.read`
- `roms.user.read`
- `roms.user.write`
- `platforms.read`
- `firmware.read`
- `assets.read`
- `assets.write`
- `collections.read`

All confirmed against RomM 5.1.0, its source, and its developer docs. The
original five were not enough for the player. me.read: the frontend asks
`/api/users/me` before rendering anything. roms.user.write: last played and
play session ingestion. collections.read: the frontend treats any 403 from
any endpoint as a dead session and bounces to its login screen, and its boot
always fetches collections, so every scope the SPA startup path touches must
be granted or the webview player gets ejected after loading. The rule of
thumb, straight from RomM's docs: 401 means bad credential, 403 means valid
credential missing a scope. Note the spec lives at `/openapi.json`, not
`/api/openapi.json`, which 404s.

---

## Screens

**Home.** Last played game, large, with a screenshot of the frame you left on and
one tap to resume. Below it, the handful of games in current rotation. This is the
launch screen, not the library.

**Library.** Two view modes only: cover grid, and compact text list with an A-Z
scrubber. Preference persists per platform slug, because arcade sets often have no
cover art and a grid of 1,204 gray tiles is worse than a text list. Segmented
control switches between all-games and platforms.

**Search.** Server-side via the API's search param, debounced.

**Detail.** ~~Cover hero, one primary action (Resume or Play), metadata.~~
Cut 2026-08-01 after building it. RomM's own player page is already a detail
screen: cover, title, Play, plus the core picker, firmware and save selection
the app has no substitute for. Ours duplicated the top half of that and added
a tap for nothing, so tapping a game anywhere now opens the player directly.
The arcade extras it was meant to carry, romset shortname and resolved control
profile, need a home if they are still wanted.

**Player.** Full screen webview, native control overlay, pause menu.

**Settings.** Server and pairing status, controls, haptics, cache.

---

## Player

Load RomM's own EmulatorJS player URL in the webview. Do not reimplement it.

Required or it breaks in ways that look like app bugs:

- `AVAudioSession` category `.playback`, or the ringer switch silences the game
- `isIdleTimerDisabled = true` while playing, or the screen locks during controller
  sessions where nothing touches the glass
- `prefersStatusBarHidden`, `prefersHomeIndicatorAutoHidden`
- `preferredScreenEdgesDeferringSystemGestures`
- Disable bounce scrolling, pull to refresh, double-tap zoom, long-press callout

**Orientation follows the device, not the game.** Revised 2026-08-01 after
building it: forcing rotation fights the system rotation lock and the user's
grip, so the app responds to how the phone is held instead of dictating it.
Portrait gets the canvas above a control strip. Landscape gets the canvas
centred with controls flanking it in the gutters. Vertical TATE games shine
in portrait and pay a canvas-size cost in landscape, and that trade belongs
to the person holding the phone.

**Canvas scaling:** largest integer multiple that fits. Never stretch to fill.

---

## Controls

### Profiles

A profile declares *logical* inputs, never physical ones. Two independent
consumers: the touch layout, and the controller mapping.

Layouts are data, not code. One JSON file per system or profile, keyed by traits
(device, display type, orientation), with normalised 0-to-1 frames. Adding a
system is a file, not a view hierarchy.

### Touch, copied from DeltaCore's model

- Every control has a visual `frame` and a larger `extendedFrame`. Hit testing runs
  against the extended frame. This is the single highest-impact detail.
- D-pad is four overlapping rects (top, bottom, left, right), each roughly a third
  of the extended frame. Diagonals fall out of the overlaps. Not a polar hit test.
- D-pad reports continuously so sliding from up to up-left is a clean stream of
  input changes, not a release and a new press.
- Haptics per input change.
- Read the approach, not the code. Delta is AGPLv3.

### Themes

Vector, not image assets, so they apply to runtime-generated layouts. Default to
system-authentic colours (Neo Geo A/B/C/D red, yellow, green, blue) because arcade
muscle memory is colour-based. Every button needs a contrasting outline regardless
of theme, or it vanishes over bright or dark game content. Opacity slider and
auto-fade matter more than the theme choice.

### Physical controllers

Capture natively with `GameController`, not the webview's Gamepad API. Suppress
the web side or every press registers twice.

- Auto-hide the touch overlay on connect, restore on disconnect, auto-pause on
  disconnect
- `buttonMenu` opens the pause menu
- Analog triggers need an actuation threshold around 0.3 with hysteresis
- Use `sfSymbolsName` and `localizedName` for glyphs so any pad labels correctly
- Mapping presets per profile per controller family, plus a press-each-button
  remap flow that handles unknown pads

Most people use Xbox or PlayStation style pads even for six-button games, so the
six-to-four fold is required, not optional:

| Arcade | Xbox | PlayStation |
|---|---|---|
| LP MP HP | X Y RB | Square Triangle R1 |
| LK MK HK | A B RT | Cross Circle R2 |

Ship a bumpers-only variant alongside it.

### RomM's own mappings

`EJS_CONTROLS` is server-side config, per core, with a `default` block merged under
a per-core block, four player slots. Fetch it, honor it as the base layer, and let
app overrides sit on top with a visible indicator when they diverge.

Per-game mapping is not modelled by RomM. If the app wants it, the app owns it,
keyed by ROM ID.

---

## Arcade

`arcade` maps to `mame2003`, `mame2003_plus`, `fbneo`, `fbalpha2012_cps1`,
`fbalpha2012_cps2`. `neogeoaes` and `neogeomvs` both map to `fbneo`. RomM has an
`ARCADE_SYSTEMS` set and ships a 17,287-entry `mame_index.json` keyed by romset
shortname with `cloneof`, `genre`, `manufacturer`, `year`.

Arcade layout is per game, not per system. Resolution chain:

1. Manual override (user picked, persisted by ROM ID)
2. Derived profile map, keyed by romset shortname
3. Parent romset via `cloneof`
4. Genre heuristic
5. Generic default, six button eight way

**Building the map:** parse `mame -listxml` offline. Its `<input>` element carries
`players`, `buttons`, `coins`; `<control>` children carry `type` and `ways`.
Classify into profiles with a few dozen rules. Ship as bundled JSON, roughly a
megabyte, well under 200KB compressed.

**Join key:** arcade ROMs must be named by romset shortname or MAME and FBNeo
cannot resolve a driver at all. Fallbacks for the edges: tag-stripped name,
parenthetical token, CRC match against MAME's per-ROM hashes, then the picker.

**Button labels** are not in MAME's XML. controls.dat has them for popular sets.
Labels are cosmetic; the index-to-core-input mapping is what matters. Ship v0.1
with generic numbered buttons and drop controls.dat in later as pure data.

**Coin is a primary control** in arcade profiles, not a small central pill.

Four-way profile must actively suppress diagonals for Pac-Man and Donkey Kong.

---

## Firmware

`GET /api/firmware?platform_id={id}` lists firmware with hashes, `is_verified`, and
`missing_from_fs`. The player builds `/api/firmware/{id}/content/{file_name}` and
passes it as `EJS_biosUrl`.

The app manages no BIOS files. Prefer `is_verified`, remember the choice per
platform when several qualify, and check availability before launch so missing
firmware produces a clear message with the filename rather than a black screen.

---

## ROM delivery

No download button. Press Play, the ROM streams from the server, EmulatorJS caches
it into IndexedDB inside the app container, and every subsequent launch is local
and offline. RomM already sets `EJS_CacheLimit` and ships a cache dialog.

Nothing cached in Safari carries over. The webview has its own container.

Explicit downloads are Phase 2, for pinning against cache eviction, Files
visibility, and large CD games.

---

## Saves and states

Two separate things that sync independently.

- **States** (`/api/states`): memory snapshots. The model has `slot`, `emulator`,
  `content_hash`, `origin_device_id`, and a `screenshot` matched by filename stem.
- **Saves** (`/api/saves`): the game's own SRAM. Survives core changes.

Slots, not a timeline, because that is what the server models. Grey out states
whose `emulator` does not match the running core. Use `content_hash` to detect
a server-side change and prompt rather than overwriting.

**Auto-state on background, auto-restore on launch.** Manual slots live in the
pause menu. The common case involves no user action at all.

RomM forces `save-state-location: browser` and exposes `EJS_onSaveState` and
`EJS_onSaveSave`. Hook both.

---

## Cut from v0.1

Layout editor. View mode sheet with four densities. Collections. Play time stats.
Netplay. Cheats. Patches. Multi-disc swapping. Offline library browsing. AirPlay.
Shortcuts and Spotlight. iPad layouts. controls.dat labels. Explicit downloads.

---

## Repo conventions

- `SECURITY.md` in the root from the first commit
- Licence decided before vendoring or porting anything from Delta or EmulatorJS
- `.gitignore` covering `DerivedData/`, `*.xcuserstate`, `.env`

---

## Open items

1. ~~Current iOS JIT behaviour in WKWebView.~~ Resolved 2026-08-01, see
   Architecture. WASM runs jitted at roughly 0.85x native Swift on iOS 26.6.
2. Whether `window.EJS_emulator.gameManager` exposes an input method, or whether
   synthetic `KeyboardEvent` is the input path. **verify**
3. ~~Exact scope identifier strings from `/api/docs`.~~ Resolved 2026-08-01.
   All five exist verbatim in RomM 5.1.0. See Auth for the corrected
   `device/init` field list, which was missing two required fields.
4. Whether the pause menu button lives in the control strip, two-finger tap, or
   both.
5. Gamepad API suppression method inside the webview.
6. Thermal and battery behaviour on PS1 and Neo Geo cores.
7. Why multi-file zip downloads fail through the reverse proxy. Blocks Phase 2,
   not Phase 1.
