# Offline play through the native player, scope

Status: phase 1 built 2026-08-07. Follows from the native player work on the
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

### Phase 2: Offline launch

- A kept game launches natively with zero network: no state-list fetch,
  no auth round trip, straight into the core.
- The launch screen degrades honestly offline: kept games show as
  playable, everything else says why it is not, rather than spinning.
- Home's resume-first flow should keep working offline for a kept game,
  which means the launch path cannot assume the session is connected.

### Phase 3: Saves written locally, synced when connectivity returns

- A state saved while offline writes to local storage immediately and
  queues its upload. Losing signal must never mean losing the save.
- On regaining connectivity (or at next online launch), queued states
  upload to RomM with their original timestamped names, so the server
  list catches up as if the saves had happened online.
- Conflicts are designed out rather than resolved: states are
  append-only files with timestamped names, nothing overwrites anything,
  so sync is only "finish the uploads," never a merge.
- The state list shown offline is the local queue plus whatever was last
  fetched, labelled honestly rather than pretending to be the server's
  full list.

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
- Kept games are visible in the Files app ("On My iPhone, Cabinet,
  Kept Games"), shipped 2026-08-07 after Marcus made the case that the
  file someone kept is theirs to copy wherever they want without a
  per-game Export ceremony. Implementation is a hard-link mirror: same
  physical bytes as the store, zero extra space, human-named. The
  private store under Application Support stays canonical and
  unexposed, so the public shape is a flat folder of game files and
  never needs to change as later phases grow the private side (this
  dissolves the layout-becomes-API objection that had deferred the
  idea). Deleting a file there un-keeps the game, store copy included,
  at the next reconcile; renames are survived by matching inodes, not
  names. Games only; firmware stays behind Export BIOS. Export itself
  remains for what the folder cannot do: iCloud destinations, un-kept
  games, BIOS-only.
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
