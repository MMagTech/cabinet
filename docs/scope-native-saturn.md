# Saturn through the native player, scope

Status: go/no-go passed, 2026-08-06. The frontend refactor landed first
against FBNeo, then Beetle Saturn was built and proved out: Sexy Parodius
(2D) and Die Hard Arcade (3D) both held full speed with clean audio for
ten continuous minutes on the iPhone Air, controls responding, on
`native-player-spike`. Integration, BIOS polish, and the third UI tier
are next, per this doc's own ordering.

## Why Saturn

Every platform in RomM's unsupported list (Dreamcast, GameCube, Switch,
PS2 and the rest) depends on dynamic recompilation and sits permanently
behind the JIT wall this app cannot cross. Saturn is the opposite case
and the only member of its tier: RomM claims support because EmulatorJS
ships a Saturn core, but that core runs slowed down and crashes mid
session in this app's own webview (confirmed firsthand, not assumed), so
the support is nominal. The accurate Saturn core, Beetle Saturn, is a pure interpreter
by design, no dynarec anywhere, which makes it the one 3D-era platform
that is JIT-boundary-legal. If a modern iPhone's CPU can carry it, the
native player turns a platform RomM pretends to support into one it
actually has. If it cannot, the ceiling is measured and written down.

This is a go/no-go, same discipline as the FBNeo spike: the performance
question gets answered on device before anything integrates.

## What the go/no-go proves

One sentence: a Saturn game boots from RomM into a natively compiled
Beetle Saturn core and holds full speed with clean audio for ten
continuous minutes on the test device.

Beetle Saturn is heavy by interpreter standards, tuned against desktop
CPUs. Whether an iPhone Air's cores hold 60 with it is genuinely
unknown, and no amount of reading replaces measuring. The go/no-go build
may be as crude as the FBNeo spike's first boot: hidden Debug button,
hardcoded game, no polish.

## What it drags in, known up front

- **The frontend refactor.** A second core means the one-file
  FBNeo-specific bridge splits into a shared frontend layer (video,
  audio, input, state plumbing) with per-core wiring, as recorded in
  memory and deferred until exactly this moment. The refactor happens
  first, against the already-working FBNeo core, so Saturn lands on a
  settled surface instead of a moving one.
- **BIOS, for real this time.** Saturn requires a real BIOS image, and
  Beetle Saturn is picky about which. RomM's firmware storage already
  serves files; the launcher already downloads them. The work is
  matching what the core demands against what the server has and saying
  so clearly when they disagree.
- **CD images, chd only.** Saturn games are cue/bin or chd; the native
  loader supports chd only, matching RomM's own recommended format for
  CD platforms and keeping the go/no-go's one question (does Beetle
  Saturn hold full speed) free of a second variable. cue/bin's own
  multi-file handling (a cue sheet plus per-track bins, downloaded
  together, the core reading references between them) is real work with
  its own failure modes that would be indistinguishable from a
  performance failure if bundled in here. Out of scope for now, not
  forever: revisit once the core itself is a known quantity and a
  concrete library needs it.
- **State sizes.** Saturn states will dwarf Neo Geo's. The existing
  per-core state tagging carries over unchanged (`saturn-native` or
  similar); the 413-too-large failure the webview already handles
  politely needs the same politeness natively.

## The third category, in the UI

Saturn today sits in RomM's supported list while being unplayable, which
is the dishonest middle. Once (if) the native core proves out, the
library and launch screens tell the truth in three tiers rather than
two: plays in the web player, plays natively only, and cannot play on
iOS. "Plays natively only" is a badge on the platform and a
native-locked Player card on the game, not a separate library section.
If the go/no-go fails, Saturn instead gets honestly marked as effectively
unplayable rather than left pretending.

## Out of scope, explicitly

- Every other Saturn-adjacent idea: Sega CD, 32X, Neo Geo CD, 3DO. One
  platform, one go/no-go, per the one-core-at-a-time cadence.
- Offline/keep-on-device for Saturn. That effort resumes after this one
  and inherits whatever lands here.
- Peripheral exotica: multitap, twin-stick, mission stick, the Saturn
  keyboard. Standard pad only.
- Any attempt to make the webview's Saturn core faster. It is not this
  app's code.

## Success and failure criteria

Success: the test game (pick a 2D-leaning title first, then a 3D one,
since 2D Saturn stresses the machine far less) reaches gameplay and
holds steady full speed with clean audio for ten minutes, controls
responding, on the iPhone Air.

Failure worth respecting: if the 3D test cannot hold full speed after
honest effort on the obvious levers (build optimization flags, the
core's own accuracy/speed options), Saturn is written down as beyond
current hardware, the frontend refactor still stands as permanent gain,
and the third-category UI work proceeds for whatever the verdict was.
Interpreter performance is physics, not a bug to grind on.
