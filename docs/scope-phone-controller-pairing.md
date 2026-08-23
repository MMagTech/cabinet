# Shipping the phone as a controller: pairing, and controller-only mode

Design settled 2026-08-22. Steps one through six below were built on
2026-08-23: the setting, code pairing, proof on every packet, browse
after a tap, the player badge, and two players. The crypto is
Curve25519 key agreement authenticated by the typed code, HKDF-derived
secrets in both Keychains, and an eight byte truncated HMAC on every
packet behind a replay window; ControllerPairing.swift's header
carries the details and the one honest limit. Controller-only mode is
not built, and the two-player step still owes its real-hardware pass.

The phone-as-controller feature already worked when this was written: a
phone drives an arcade game running on an Apple TV, with the game's
real cabinet panel drawn on the phone, verified across a full day on
real hardware. It shipped to nobody because it was `#if DEBUG`, and it
was behind that gate for one reason: **there was no authentication on
the wire at all.** Anything on the network could send input to a
television mid-game.

This document is how that got solved, and a second idea that fell out
of solving it. The gate is off now; the socket answers to the setting
and the pairing below instead.

## Why this matters more than it looks

It is not polish on an optional feature. It is the only thing standing
between a finished feature and the people using Cabinet. It also blocks
two-player, and it is the only route to a real touchscreen for a
Nintendo DS running on an Apple TV.

## What was originally planned, and why it changed

The notes from when the feature was built listed three separate things
to build: presence from RomM rather than Bonjour, a token handshake, and
a first-join accept per phone. Three mechanisms, three designs.

They are all the same question, which is "has this phone been allowed to
drive this television before", and one mechanism answers all three.

## The design: pair the phone to the television, once

**On the television**, a setting: "Allow a phone as a controller", off by
default. Nothing binds a socket until that is on AND a game is running.

**First time a given phone connects**, the television shows a short code
on screen. You type it on the phone. Both sides store a shared secret
for each other. That is the last time anyone does this for that pair of
devices.

**Every packet afterwards carries proof of that secret**, checked before
a single byte of input is parsed. No proof, no parsing.

**Discovery stays on Bonjour**, but the phone only browses after someone
taps to connect. Two consequences, both good: nobody who ignores the
feature ever sees iOS's local-network permission prompt, and a phone on
a stranger's Wi-Fi finds their television, fails to prove anything, and
does nothing.

That last point is why this is simpler than the original plan. The whole
RomM-presence requirement existed to stop a phone browsing where it
should not. Pairing makes browsing harmless, so the requirement
disappears rather than needing to be solved.

It also matches a model Cabinet's users already understand, because it is
how Cabinet pairs to RomM: a code appears, you approve it once, it never
asks again.

### Why not use the RomM account as the identity

It was considered seriously: the phone hands over its RomM token, the
television asks its own server "who is this", and allows a match. It
needs no new permissions, since reading your own identity is `me.read`
which Cabinet already has, and it needs no setup step at all.

Two things killed it. It does not work for anyone without a RomM account,
which rules out guests entirely, and it does not protect a household
sharing one account, where being the same account is not the same as
being invited.

**Also verified dead, do not re-propose:** sharing a secret through
iCloud so the two devices never have to meet. tvOS does not participate
in iCloud Keychain at all. See
[scope-icloud-pairing-continuity.md](scope-icloud-pairing-continuity.md),
where this was built, tested on a real Apple TV, and abandoned.

### Decisions taken while walking through real scenarios

**A second person joining mid-game does not interrupt the first.** The
code appears as an overlay in a corner and the running game is not
paused. Someone standing in the room wanting to join is not a reason to
stop somebody else's run.

**Physical presence is the boundary, deliberately.** A code on the
television can be read by anyone in the room, so anyone in the room can
join. That is the same boundary a console has always had, which is
handing somebody a controller. The alternative, the television asking
"allow this phone?" and waiting for the current player to answer, gives a
veto and costs an interruption every first join. Presence was chosen; the
coarse veto is turning the setting off.

**Ports are first come, first served, and sticky**, which is the rule
`GameControllerManager.slotIndex(for:)` already implements for pads. The
first source to claim a slot keeps it, so a pad connecting after a phone
has joined does not silently demote the person already playing. Two
slots, `GameControllerManager.maxPlayers`; a third source is simply not
a player, exactly as a third gamepad behaves today.

**A phone needs a stable identity across reconnects.** Pads get this free
because the same physical controller returns as the same object. A phone
that drops off Wi-Fi for two seconds is a new connection, and without an
identity two players could silently swap ports mid-game, which is the
worst kind of bug because it looks like the game went mad. The paired
secret is the natural identity.

**The companion panel should say which player it is.** A pad has no
opinion about this because a human plugged it in. Two people staring at
identical panels not knowing who is who is a bad first thirty seconds.

## Controller-only mode

Cabinet will not show anything until it is paired to a RomM server:
`Session.Stage` has exactly three states and only `ready` reaches the
app. So a friend who visits with a phone and no account cannot join,
even though the controller half needs nothing from RomM.

**A fourth state fixes that.** Install Cabinet, skip setup, and the app
is a controller and nothing else: find a television that has admitted
you, draw its panel, play.

Three reasons this is worth more than it first appears.

**It settles the authentication question.** A guest has no RomM identity,
so if this mode exists, RomM identity cannot be the mechanism. Code
pairing is the only thing that works for everyone, and it is the simpler
option anyway.

**It may solve the App Store review problem.** The recorded risk was
never rule 4.7, it was reviewability: a reviewer cannot meaningfully test
an app that needs a self-hosted server they do not have. Controller-only
mode is a fully functional part of the app requiring no server at all.

**It is less app, not more.** No library, no downloads, no RomM client,
no save syncing. A root state, a way to find a television, and the panel
that already exists.

**The hard part is the front door**, and it is copy rather than
engineering. Someone installing Cabinet for a game library must not land
in controller mode by accident, and someone who only wants a controller
must not feel they failed to finish setting something up.

Not for the first pass. But the pairing design above deliberately leaves
this door open rather than closing it, and that is worth preserving.

## Order to build

1. The television's setting, and a socket that only exists while it is on
   and a game is running.
2. Code pairing, and the stored secret on both sides.
3. Proof on every packet, before parsing.
4. Browse only after a tap.
5. Player number on the panel.
6. Two players, which is mostly the slot rule already written.
7. Controller-only mode, later, once the rest is real.

## Still open

Whether a paired secret survives the app being reinstalled on either
side is whatever each platform's Keychain does; nothing here promises
it. What re-pairing feels like when it does not survive is now
answered in behavior: a side that lost its secret is simply sent
through pairing again, a fresh code on the television, automatically,
and the new secret overwrites cleanly on both sides. Deliberately
forgetting a pairing from either side's settings has no UI yet.
