# Offline play through the native player, scope

Status: all three phases built 2026-08-07. Follows from the native player work on the
`native-player-spike` branch (see scope-native-player-spike.md, whose
spike succeeded and whose integration landed 2026-08-06).

## Why this exists

The webview player can never be truly offline: it loads RomM's EmulatorJS
page from the server every launch, so no amount of client caching removes
the server from the loop. The native player inverts that. The core is
compiled into the binary, the controls are native, and saves go through a
plain API. The only thing standing between a native-capable game and
airplane-mode play is the ROM file. That makes offline support a natural
consequence of the native path rather than a feature bolted onto the
webview, and it is exactly the kind of capability that justifies the
native player existing beyond crash avoidance.

Caching for its own sake is explicitly not the frame. The native launcher
currently re-downloads every launch, which needs fixing anyway, but the
product answer is not a silent cache: it is a deliberate, visible "this
game lives on my phone now."

## The shape

Three pieces, phased. Each phase is independently shippable and the
earlier ones are useful without the later ones.

### Phase 1: Keep on device

- A per-game toggle on the launch screen, offered only for games the
  native player can run, because only there is the offline promise
  honest.
- Keeping a game downloads its ROM and its platform's firmware into
  permanent app storage, keyed by rom id. Shown with its size. Removable
  the same place it was added.
- Kept games are not a cache. Nothing evicts them silently. The existing
  Cache screen gains a section listing kept games and their total, so
  storage lives in one place, but the semantics differ on purpose:
  caches serve speed, kept games serve a promise.
- The native launcher checks kept storage before downloading, which
  retires the every-launch re-download as a side effect.
- Temp directories from un-kept native launches get cleaned up on exit
  rather than left for iOS to purge.

### Phase 2: Offline launch (built 2026-08-07)

- A kept game launches natively with zero network: `GameLaunchView`
  checks `NetworkMonitor` up front and skips the firmware/saves/states
  fetches entirely when offline, rather than waiting out three doomed
  timeouts, exactly the spinner this phase was scoped to remove.
- Keep now also downloads the newest save state for a kept, native-
  capable game, and keeps it current for free on every ordinary online
  visit to that game's launch screen afterward. A locally cached state
  populates the Resume-from list with zero network, so a kept game
  resumes real progress offline rather than always booting fresh, and
  is preferred over a network fetch even online whenever it is the
  state actually selected, since a round trip for a state already on
  the phone only slows things down. States stay internal, never linked
  into the Files mirror: RomM's own library has no states folder, and a
  state blob is core-format-specific, no use to another app the way a
  ROM is. Confirmed with Marcus before building.
- Reached at length before any of this was built: a state cached at
  keep time and refreshed opportunistically whenever there is a
  connection is the right shape, not a queue, because Cabinet already
  does a live fetch every time it is online, so it is never stale while
  it has signal; the only real gap was the narrow window between the
  last live check and actually losing signal, closed by refreshing on
  ordinary use rather than needing a background job. Multi-device
  staleness (a save made on another client while Cabinet is offline)
  does not need solving on this read side either, it is exactly what
  phase 3's already-scoped append-only upload queue exists for.
- `Rom` gained `Encodable` so `KeptGame`'s manifest can embed the whole
  rom a game was kept from, not a hand-picked subset. That is what
  makes offline navigation possible: Home now shows every kept,
  native-capable game as its offline resume-first answer (not just the
  single most recent one, which nothing local persisted before this),
  each with real cover art and platform label, reached the same way any
  other game is. Webview-only kept games are deliberately left off that
  list: their player still needs the server to start, so listing them
  would set up a tap that fails.

### Phase 3: Saves written locally, synced when connectivity returns (built 2026-08-07)

- A state saved on a kept game writes to local storage first, before
  any attempt to reach RomM, in `KeptGameStore`'s own per-game
  `pending-states` directory. Losing signal mid-save never means
  losing the save; a game played natively without being kept still
  saves directly, since native play without a connection was never
  possible for it anyway.
- Conflicts are designed out rather than resolved: each queued file
  already carries RomM's own timestamped name (`stateFileStem()`), so
  an upload lands exactly as if it had happened online, nothing
  overwrites anything, sync is only "finish the uploads."
  `KeptGameStore.syncPendingStates` is safe to call often: a file that
  uploads successfully leaves the queue, one that fails stays for the
  next attempt.
- Upload is automatic and app-wide, per Marcus: `RommApp` observes
  `NetworkMonitor` directly and syncs on foreground, on the connection
  itself changing, or the manual toggle turning off, not only when the
  specific game's screen happens to be revisited.
- Every queued save shows as its own row in Resume-from, not just the
  newest, matching "the local queue plus whatever was last fetched"
  above literally: a trip with several saves offers every one of them
  back. Loading falls back through local sources before ever asking
  the network, and the pause menu's own "Load latest state" now
  prefers the newest local save when offline instead of failing.
- Visibility: a terse "N saves waiting to upload" appears on the
  game's own Storage card and in the Storage settings list once
  something is queued (Marcus: saves are important enough to warrant
  this, not fully silent).
- Wording settled after a direct correction: the pause menu's offline
  save status is "Waiting for signal to upload.", not a longer
  "Saved on this iPhone, uploads once you're back online" draft,
  since being offline already implies the save is local, no need to
  say so twice, a standing correction to this project's UI copy, not
  a one-off.

### Same-day follow-on: the app notices offline, live, not on request

Phase 2 shipped checking connectivity at specific moments, screen open,
a boot stall. Nothing watched it continuously, so a screen already on
screen had no way to react to a change; Marcus caught this directly
("I have to exit it and then reenter to see offline view"). Built and
shipped 2026-08-07, same session:

- `NetworkMonitor` became a `@MainActor ObservableObject` with
  `@Published isConnected`, not an actor with a polled property. Home
  and Library both observe it and re-run their own existing load
  functions the instant it changes, live.
- A second, separate signal: a manual Offline Mode toggle (Marcus's
  idea, the Low Data Mode shape, not a signal-loss fallback: forcing
  the app to act offline on purpose, roaming, a capped hotspot, or just
  not wanting a download to fire on signal you don't trust). Real
  suppression, not cosmetic, load functions check it before touching
  the network at all. `NetworkMonitor.isOffline` combines both signals
  into the one thing every screen actually asks, so real disconnection
  and the deliberate choice drive identical code paths everywhere,
  never a second offline system to maintain for the manual case.
  Surfaced as a real `Toggle` styled as a button in Home's toolbar,
  airplane icon, tinted when on, matching how iOS itself treats a
  standing mode rather than a one-shot action; invisible, not disabled,
  when there are no native-capable kept games to switch to.
- Two bugs found chasing this, both about a screen destroying good data
  it did not need to: Library's loading spinner, offline banner and
  error text all unconditionally hid an already-successful platform
  list; now gated on the list actually being empty, so a failed
  background refresh can correct or add to what's showing but never
  erase it. And the manual toggle needed a force-quit to show anything
  at all, because Home's offline view was itself gated on already
  having nothing cached, correct for protecting content from an
  accidental blip, wrong for a deliberate toggle that has to visibly do
  something the instant it's flipped; both screens now let the manual
  case bypass that gate outright.
- Library's biggest gap: it went completely dark behind `OfflineNotice`
  the moment either kind of offline was true, discarding kept games
  entirely rather than surfacing them (Marcus: "Offline should show
  platforms that have games downloaded for them"). `RomListView` gained
  a `keptPlatform` source, roms assigned directly with no fetch, so
  Library now groups kept, native-capable games by platform and routes
  into the exact same grid/list screen live browsing already uses,
  badges and context menu included, rather than a second screen built
  just for this. Webview-only kept games excluded, same rule as Home's
  offline list, their player still needs the server regardless of what
  is stored.
- Wording is centralized: `NetworkMonitor.offlineReason` picks "No
  connection" or "Offline Mode" depending on which is actually true, so
  a screen can never claim no signal while the real cause is a
  deliberate choice with full bars showing, the exact bug a screenshot
  caught.
- Consolidated same day: Home's offline list and the library's were two
  separately maintained copies of the identical grouping the moment
  both existed, and Marcus caught it comparing them directly ("why
  would the two need to exist... we just need a home"). `OfflineLibraryView`
  is now the one place this is drawn, platform grouping, label
  formatting, the `OfflineNotice` fallback, all of it; Home and Library
  each just show it with their own retry action.
- The library tab itself is hidden outright while Offline Mode is on
  ("if both tabs are the same why two... drop the library and keep the
  home"), selection falls back to Home if someone was standing on it
  when the toggle flipped. Search stayed, unlike Library: finding one
  game by name across everything kept is not redundant with Home's
  platform list the way Library's content was, so it was fixed instead
  of dropped, scoped to kept games with the same real-suppression rule
  as everywhere else (Marcus caught it still leaking live server
  results).
- The game launch screen itself was the last gap: it let the web player
  be selected and "launch" offline, which could only stall, since
  nothing checked connectivity before presenting `PlayerView`. The
  Player card now vanishes offline the same way it already does for
  Saturn, no picker where there is no real choice, backend forced to
  native, live if the toggle flips mid-view. Separately, the Storage
  toggle's remove action is a real, permanent-until-signal-returns
  deletion, an easy accidental tap on a screen with no undo (Marcus:
  "I can't think of a situation... they can go to files instead of
  accidentally triggering in UI"); it disappears entirely once a game
  is both kept and offline, informational caption unchanged, Files
  staying the deliberate path for that action. A not-yet-kept game's
  toggle stays visible but disabled offline, greyed rather than hidden,
  since a failed download attempt costs nothing to undo. Saves
  (`GameSave`, distinct from states) were confirmed as a non-issue
  while looking at this: they were never wired into native play at all,
  online or off, so their offline emptiness is correct, not a gap.

## Decisions already made

- Offline support is native-player-only. The webview player is not asked
  to work offline and never will be; see the why above.
- Kept ROMs are excluded from iOS backup. RomM is the source of truth
  and every kept file is re-downloadable from it; backing them up would
  bloat iCloud backups to protect data that is not at risk. Confirmed by
  Marcus 2026-08-07. No user-facing setting for this: a toggle whose
  tradeoff needs two paragraphs to explain mostly generates support
  questions, and it can be added later without migration pain if anyone
  actually asks, since it is a per-file flag flip either way.
- Keeping a game always downloads fresh from the server, even when a
  copy already exists somewhere on the phone. An exported ROM is
  invisible to the app once Files has it (iOS design, not ours), and
  Data Saver's copy lives inside the webview's own cache serving the web
  player; the overlap with native-capable games is arcade-only, where
  ROMs are small. Plumbing bytes between three storage systems to save a
  few megabytes of download would couple the native offline path to the
  webview machinery it exists to escape. The reverse directions are
  different and do ship, and together they became the unified storage
  model (Marcus, 2026-08-07, "why isn't there just one copy?"): the kept
  store is the single source of truth, and everything else references
  it. The native player boots from it directly. The web player's cache
  is seeded from it at keep time, locally through the existing bridge,
  making that cache a disposable projection rather than a peer store.
  Export copies from it instead of downloading again. Data Saver is gone
  as a person-facing feature; its injection machinery became the seeding
  plumbing. Every playable single-file game gets the one Keep toggle,
  with fine print carrying the per-player promise: native-capable games
  play fully offline, webview games skip the big download but still need
  the server to start, which is the webview's physics and why offline
  proper stays native-only. The Cache screen became Storage: kept games
  in one section, the web player's cache in another, clearable without
  ever touching a kept game.
- Known soft edge, accepted: if the web player's cache evicts a kept
  game's projection, nothing re-seeds it automatically until the game is
  un-kept and re-kept; the web player just downloads organically that
  once and re-caches itself. Phase 2 may revisit.
- Kept games are visible in the Files app under On My iPhone, Cabinet,
  shipped 2026-08-07 after Marcus made the case that the file someone
  kept is theirs to copy wherever they want without a per-game Export
  ceremony. The layout mirrors his server's actual library structure,
  system folder first: <platform folder>/roms/<server filename> and
  <platform folder>/bios/<firmware filename>. RomM supports two
  structures and the first cut assumed the other one blind, which he
  caught; the app cannot ask the server which structure it uses, so
  this matches his instance and stays until that matters for someone
  else. Server filenames keep name collisions impossible, the server's
  directories already guarantee uniqueness. Implementation is a hard-link mirror: same physical bytes
  as the store, zero extra space. The private store under Application
  Support stays canonical and unexposed, so the public shape never
  needs to change as later phases grow the private side (this dissolves
  the layout-becomes-API objection that had deferred the idea).
  Deleting the ROM there un-keeps the game, store copy included, at the
  next reconcile; renames and moves within the folder are survived by
  matching inodes, not names or locations. Firmware links in alongside
  the ROMs, shared across a platform's kept games and removed with the
  last of them; deleting a BIOS file in Files is not read as intent,
  it's platform infrastructure and reconcile restores it. Export ended
  the day reduced to a single remnant: multi-file ROMs, which the
  download machinery cannot fetch yet, a capability gap with a named
  successor (teach keep multi-file downloads, mirroring the server's
  game folders) rather than a design carve-out. Every single-file
  game, unsupported systems and keyboard machines included, shows one
  visible action, the storage toggle. Unsupported games caption it
  with nothing but the size: the library labels them unsupported, the
  platform name is on the screen, and the folder in Files says the
  rest. Marcus held the line on one-visible-action through three of
  my hedges and was right every time.
- Save states remain per-core, per the state-format finding in the
  native player work: an offline save from the native player syncs up
  tagged fbneo-native, same as an online one.

## Out of scope, explicitly

- Offline library browsing beyond kept games. The library is the
  server's; this effort is about playing, not mirroring RomM.
- Offline for webview-only platforms, per above.
- Any peer-to-peer or iCloud sync of saves between devices. RomM is the
  sync point, full stop.
- Download-over-cellular policies, background downloading, and
  auto-keeping recently played games. All plausible, all later.

## Failure worth respecting

Phase 1 is weekend-sized. If phase 3's queue-and-sync grows past that on
its own, it ships separately rather than holding the keep toggle
hostage. A kept game that plays offline but saves only online is already
most of the promise.
