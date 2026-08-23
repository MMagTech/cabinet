# Settled questions

Ideas that got a real look and a real answer, kept here so nobody spends
another evening re-deriving one. This is not the roadmap, nothing below is
in progress or planned. Revisit an entry only on a genuine change in what
caused it, a new RomM release, a new Apple platform capability, not because
it would be nice again.

## A native macOS build

**Off the table, permanently.** tvOS's UI is built entirely around the focus
engine with no cursor and no keyboard, so it does not port to a Mac's
pointer-and-keyboard model. The closer relative is iOS, and Mac Catalyst
exists specifically to run an iOS SwiftUI app on macOS with a real window
and pointer support largely for free.

The mechanical port would be genuinely easy, a few days of work, since
auth, the API client, `GameController` input and Metal rendering all carry
over. What would not be free is making it feel like a real Mac app rather
than a stretched iPad window: real window behavior, a menu bar, keyboard
shortcuts. None of that has been scoped.

The more interesting question underneath was never the UI, it was the JIT
boundary. iOS and tvOS force every native core to run as a pure interpreter
because only WKWebView's WebContent process gets Apple's dynamic code
signing entitlement, not the app's own process. A native Mac app has no such
restriction, so PS1's forced interpreter and any future N64-class core could
in principle run with a real dynamic recompiler on a Mac. Nobody has
followed that thread.

PS2, GameCube, Wii, 3DS and Switch were raised alongside this and are a
separate question entirely. Cabinet's whole architecture is one binary of
symbol-scoped libretro cores, deliberately not RetroArch-style dynamic
loading. Those systems are not libretro-core-scale additions, they are each
a standalone flagship emulator project with years of dedicated team effort.
Embedding one of those is not "add a core," it is taking on a second large
open source project, and it would need its own conversation regardless of
platform.

## Uploading a ROM from Cabinet

**Declined.** The idea was a long press on a platform to upload a file you
were handed on the go, without turning Cabinet into an admin surface. Two
independent things stop it, verified against a live RomM 5.1.0 server
rather than assumed.

Upload needs the `roms.write` scope, and that same single scope is also
"Delete Roms" and the generic ROM-edit endpoint. RomM has no narrower
create-only scope. Since scopes are fixed at pairing time, shipping this
would mean every existing pairing goes from "read your library" to "delete
your library," for a case that comes up a few times a year.

Even with that scope granted, the uploaded file would not appear anywhere.
The upload endpoints write the file to disk and return success with no
database row and no indexing. The game does not exist in RomM until a
library scan runs, and there is no way to trigger a scan through the API
Cabinet can reach: it is a privileged, destructive socket.io operation, and
the REST equivalent explicitly disallows being run on demand.

Revisit only if RomM ships both a create-only scope and upload that indexes
the file on its own. One alone is not enough.

## Atari Jaguar as a native core

**Declined rather than deferred.** The core itself, `virtualjaguar-libretro`,
is in much better shape than the console's reputation. What killed it is the
console, not the emulator: only 63 licensed games ever shipped for it, which
is a small return for a controller with a twelve-key numeric keypad that
would need its own control scheme solved.

## Skipping setup on a new device via iCloud

**Abandoned, not built.** The idea was a brand-new device signed into the
same Apple ID as one that already knows a RomM server picking up that
pairing automatically, so nobody has to type a server address or redo
device authorization by hand.

It was designed, built, and taken to real hardware, where the Apple TV half
turned out to be impossible: tvOS does not participate in iCloud Keychain
sync at all, so a seed written on a phone can never arrive there. That
removed the only case anyone actually cared about, since setting up a phone
was never the hard part. The iPhone-to-iPhone half did work and was dropped
anyway, since what was left of its value, saving one typed address on a new
phone, did not justify silently copying a bearer token for someone's private
server into iCloud with no way to opt out.

Two alternatives were checked and rejected alongside it. Approving a pairing
from inside Cabinet on your phone, the way Discord signs you in on a TV,
needs RomM's `me.write` scope, which also grants minting fresh API tokens
and modifying the account, too broad a trade for skipping one screen. RomM's
own server-side QR pairing (`/api/client-tokens`) was checked too and hits
the same wall, it also requires `me.write`. A direct phone-to-TV handoff over
the local network is the only remaining route that removes typing the
address, and it was not taken for now: it is the most code of the three and
only helps at home.

Full reasoning, the six design questions this went through, and the test
plan for if it's ever revisited: [docs/scope-icloud-pairing-continuity.md](scope-icloud-pairing-continuity.md).
