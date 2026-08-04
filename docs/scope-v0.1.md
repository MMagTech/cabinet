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

**A game is played in the orientation it was started in.** Revised 2026-08-02
after living with free rotation on device: resizing the webview mid game makes
WebKit relay everything out over a wasm core already near its process memory
ceiling, and iOS sometimes kills the process for it. Crash recovery makes that
survivable, but even a graceful recovery interrupts a live run, and an
interruption during a boss is a lost run. So the player locks to the
orientation it opened in (see `OrientationLock`) and the rest of the app
rotates freely. Portrait gets the canvas above a control strip. Landscape gets
the canvas centred with controls flanking it in the gutters. The TATE trade
still belongs to the person holding the phone, decided by how they hold it
when they press Play.

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

**Auto-state on background, restore by consent.** Revised 2026-08-02 after
building it: a local autosave is written every thirty seconds of play and at
the moments a kill is likeliest, and crash recovery restores it silently. A
session iOS evicted gets a preselected "continue where you left off" card at
the next launch rather than a silent restore, because a deliberate exit must
start fresh and only an interrupted one should come back. Manual slots live
in the pause menu.

RomM forces `save-state-location: browser` and exposes `EJS_onSaveState` and
`EJS_onSaveSave`. Hook both.

---

## Next

Agreed 2026-08-02, in this order. Each was cut from v0.1 and has earned its
way back for a stated reason, not because the list looked short.

**1. Offline library browsing.** No network currently means no app at all:
Home is empty, the library is empty, and you cannot even see what you own.
That is a thin client feeling on a device that spends real time on planes and
subways. Cache the game list, the platforms and the cover art, and say plainly
in the UI that starting a game still needs a connection. Deliberately not
offline *play*: RomM serves the player page as `no-cache` and its page needs
the network, so playing offline would mean serving EmulatorJS from inside the
app, which contradicts "load RomM's own player, do not reimplement it". That
trade is not worth reopening for this.

**2. Save states you can see.** The launch screen's resume card is a list of
identical filenames, which is useless for choosing. RomM stores a screenshot
alongside every state and the app already uploads them, so the data is sitting
there. Thumbnails turn the weakest screen in the app into one of the better
ones and make the pause menu's save and load loop legible instead of an act of
faith. Best payoff for the effort on this list.

**Done, 2026-08-03: the console pad is the wrong shape for most consoles.**
Was down to two bundled touch layouts, `default.json` and `gb.json`, and
every console platform that was not Game Boy got `default`, two face
buttons only. Fifteen pad shapes now cover every non-computer, non-arcade
platform RomM's core map lists, sourced from EmulatorJS's own code where the
mapping was not obvious rather than guessed, including a real analog stick
for N64 (a new `stick` item kind, not previously possible), which was
expected to need blocking the way keyboard machines are and did not: its
buttons are ordinary digital buttons, and the stick was buildable once
looked into properly. Nintendo DS turned out to need no new engineering
either, its touch screen is real `WKWebView` content the control strip
already leaves uncovered. Moving the controls, a real editor since layouts
are already normalised 0 to 1 data, is the natural follow on now that the
shapes themselves are correct, but is not on this list yet.

A second pass the same week fixed two more real gaps, both found by
playing, not by auditing: twin-stick arcade games (Smash TV, Robotron)
were missing an entire required input, since `ArcadeProfile` only ever
modelled one joystick, not the second one these games are built around.
MAME's own "doublejoy" control type was already being classified for this
by `tools/mame_profiles.py`, just never read on the Swift side. And every
layout's button hit testing had a real bug, not just a spacing one: two
buttons whose generous extended zones overlapped both fired on a touch in
that overlap, which read as accidentally hitting two buttons on any dense
layout, arcade worst of all. Both verified live on device, not just in the
simulator.

Rollerball and dial controls (Arkanoid's paddle, Tempest's spinner,
Centipede and Marble Madness's trackball) are a related, larger gap,
deliberately not attempted alongside twin-stick: a second joystick was
obviously the same shape as controls this app already draws, continuous
rotation and unbounded relative motion are not obviously anything, and
whether either can be made to feel good on a touchscreen at all is an open
question, not just an unbuilt one. Worth a real feasibility pass before
committing to it, not a guess.

**Done, 2026-08-03: Collections.** RomM models them, the app now reads
regular user made collections, browsable from a segmented control on the
Library screen alongside platforms, same `RomListView` grid or list either
one uses. Deliberately not virtual collections (metadata groupings like
genre or franchise, the thing that actually solves 1,200 arcade games
having no grouping beyond A to Z) or smart collections (rule based, the
least likely thing anyone running a personal instance has actually set
up): user collections were the same shape as the Favourites collection
this app already reads, so shipped first; the other two remain real,
unscheduled work, not abandoned.

**3. Download for platforms this app cannot run.** Settled 2026-08-03. Not
every platform RomM lists is playable in a browser at all: Dreamcast is
absent from RomM's own core map entirely, and Flash runs through Ruffle, an
engine this player does not integrate with. Neither is a bug; both are limits
of what EmulatorJS itself can run. The honest fix is not to hide the game,
it is to stop offering a Play button that leads nowhere and offer the
alternative instead: download the ROM, and its BIOS if the platform needs
one, so the game is still usable through RetroArch or another native
emulator. This rides on the same ROM fetch machinery offline browsing needs,
so it belongs right after it, not as a separate project.

A second, deliberately separate reason lands here too, settled 2026-08-03:
keyboard machines, C64, Amiga, DOS and the rest, `ComputerPlatforms.swift`.
Not unplayable by EmulatorJS the way Dreamcast is; unplayable *by touch*,
which this app does not pretend to fix with a bad on screen keyboard. The
launch screen blocks Play on these today with a plain explanation. Download
is the planned way out for them too, once this item exists; an on screen
keyboard is not planned at all, stated in the code as a decision rather
than a gap. A physical Bluetooth keyboard should already reach these games
today with no app support needed, reasoned from the code, not yet confirmed
on a real keyboard: nothing here intercepts hardware key events before a
WKWebView delivers them, and EmulatorJS has its own keyboard handling for
exactly these cores.

Netplay was considered on 2026-08-02 and declined, with reasons worth keeping
because they will come up again. It is entirely socket based over
`/netplay/socket.io`, and sockets are this app's known weak spot: RomM's
activity socket does not survive the webview, which is why play reporting had
to move to REST, and netplay has no REST to fall back on. The web process
still dies unpredictably, and in a match that strands the other player rather
than costing seconds. EmulatorJS netplay is lockstep rather than rollback, so
two phones on cellular would feel bad in exactly the games that would want it.
And RomM's own page sets no netplay configuration, so the app would be reaching
past it into EmulatorJS internals, which is the coupling that breaks the
existing third party client across versions. Revisit only if a socket is first
proven to survive the webview.

---

## Cut from v0.1

View mode sheet with four densities. Play time stats. Netplay. Cheats.
Patches. Multi-disc swapping. AirPlay. Shortcuts and Spotlight. iPad layouts.
controls.dat labels. Explicit downloads.

Layout editor, collections and offline library browsing moved to Next above.

---

## Repo conventions

- `SECURITY.md` in the root from the first commit
- Licence decided before vendoring or porting anything from Delta or EmulatorJS
- `.gitignore` covering `DerivedData/`, `*.xcuserstate`, `.env`

---

## Open items

1. ~~Current iOS JIT behaviour in WKWebView.~~ Resolved 2026-08-01, see
   Architecture. WASM runs jitted at roughly 0.85x native Swift on iOS 26.6.
2. ~~Whether `window.EJS_emulator.gameManager` exposes an input method.~~
   Resolved 2026-08-01. `gameManager.simulateInput(player, id, value)` is the
   same call EmulatorJS's own touch and gamepad paths use; no synthetic
   `KeyboardEvent` needed. See `PlayerInputBridge`.
3. ~~Exact scope identifier strings from `/api/docs`.~~ Resolved 2026-08-01.
   All five exist verbatim in RomM 5.1.0. See Auth for the corrected
   `device/init` field list, which was missing two required fields.
4. ~~Whether the pause menu button lives in the control strip, two-finger tap,
   or both.~~ Resolved 2026-08-02: a Menu pill on the pad, out of the thumb
   arcs, plus the controller's Menu button. Both freeze the emulator on the
   press, before the menu is even drawn, because a pause that arrives late is
   a death in anything that shoots back. The native menu holds Resume, Save
   state and Quit; saving posts to RomM's states API directly and reports
   what happened, including the payload too large case that a CV1000 sized
   state hits on a default proxy body limit.
5. ~~Gamepad API suppression method inside the webview.~~ Resolved 2026-08-01.
   `navigator.getGamepads` is replaced with an empty function and the connect
   events are stopped in capture phase; EmulatorJS polls, so that is the whole
   suppression. See the auth injection in `PlayerView`.
6. Thermal and battery behaviour on PS1 and Neo Geo cores.
7. Why multi-file zip downloads fail through the reverse proxy. Blocks Phase 2,
   not Phase 1.
