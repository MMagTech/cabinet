# Offline play through the native player, scope

Status: proposed, not started. Follows from the native player work on the
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
  bloat iCloud backups to protect data that is not at risk. (Flagged for
  Marcus's confirmation at session start, default stands unless he
  objects.)
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
