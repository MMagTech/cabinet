# iCloud pairing continuity

Design only. Nothing here is built, and nothing here has touched a device.

A brand new device signed into the same Apple ID as a device that already
knows a RomM server should be able to skip typing the address and redoing
device authorization. The mechanism is iCloud Keychain sync, nothing
server side and nothing on the network.

The grounding, the mechanism check against real code, and the safety
boundary were worked out on 2026-08-14 and are not repeated here. This
document picks up at the six questions that were left open, answers five
of them, and records what still needs Marcus.

## What this touches, and why that crosses the platform rule

CLAUDE.md says not to edit iOS or shared files during tvOS work and the
reverse. This feature cannot honour that, because it is a handshake:
iOS writes the seed, shared code holds it and consumes it, tvOS reads it
and offers it. All three are in scope by nature, not by drift. Files:

- `RommApp/RommApp/Auth/Keychain.swift`, shared. Gains a second, separate
  synchronizable item. Its existing token storage is not touched.
- `RommApp/RommApp/Auth/Session.swift`, shared. Writes the seed on iOS at
  the two moments below, clears it on `forgetServer()`, and gains an
  adopt call the TV uses.
- `RommApp/RommApp/UI/ServerSetupView.swift`, shared. Gains the offer
  card, tvOS only for now.
- `RommApp/RommAppTV/TVProfileStore.swift`, tvOS. Profiles gain a local
  address, which is a fix worth having on its own (see Q6).

## The seed

One Keychain item, separate from everything that exists today.

    service       com.mmagtech.RommApp.pairingSeed
    account       seed
    synchronizable true
    accessible    kSecAttrAccessibleAfterFirstUnlock

`kSecAttrAccessibleAfterFirstUnlock` is what the token already uses and it
is one of the tiers that can sync. The `ThisDeviceOnly` tiers cannot, so
this is not a downgrade, it is the same tier with sync turned on.

Value is JSON:

    {
      "version": 1,
      "pairings": [
        {
          "host": "romm.example.com",
          "pairedAddress": "https://romm.example.com",
          "secondAddress": "http://192.168.1.10:6005",
          "token": "...",
          "username": "marcus",
          "updated": "2026-08-15T18:00:00Z"
        }
      ]
    }

`secondAddress` and `username` are optional. Entries are keyed by `host`,
so pairing the same server again replaces its entry instead of adding a
duplicate. Most recent three are kept, oldest by `updated` dropped.
Bounded because it is a synced item and because every entry holds a
bearer token.

**The format is versioned on day one and that is not ceremony.** A synced
item is read and written by devices on different app versions at the same
time, which makes it materially harder to migrate than the local formats
this project has changed before. Two rules cover it:

- A reader that sees a `version` it does not know ignores the whole seed
  and behaves exactly as if there were none. Inert, never a partial read.
- A writer that sees a `version` higher than its own does not write at
  all. An older phone declining to contribute is much better than an
  older phone clobbering a newer phone's seed.

## Who writes it

Only iOS, which is the settled safety boundary: a phone is unambiguously
one person, a TV is not. iOS writes on exactly two events:

- `completePairing` succeeds, which is the only moment a new token exists.
- `setLocalAddress` succeeds, which is the only moment the second address
  changes.

`connect(toAddress:)` finding an existing token produces no new
information and does not write.

The TV never writes this item. It writes `Session`, `TVProfileStore` and
its own local Keychain entries as it always has.

## When a device reads it

The gate is the one already settled: only on a device that knows no
server. On tvOS that also means zero profiles. That maps cleanly onto
code that exists, because tvOS first run goes through the shared
`ServerSetupView` and `RommAppTV.syncFirstProfileIfNeeded` backfills the
first `TVProfile` once `Session` reaches `.ready`. So the offer belongs
on `ServerSetupView`, shown only when `session.stage == .needsServer`,
and on tvOS additionally only when `TVProfileStore.profiles.isEmpty`.

**iOS reads it too.** Only iOS writes, but both platforms read, which was
the original intent and which an earlier draft of this document narrowed
to tvOS by mistake. The case that makes it obvious is deleting Cabinet
and reinstalling it later on the same iPhone: UserDefaults goes with the
app, so the server address is lost, and today that means typing it again.

**Checked 2026-08-15, and it holds.** iOS Keychain items survive app
deletion while UserDefaults does not. This was never documented, Apple
tried removing it in an iOS 10.3 beta, apps broke because they had come
to rely on it, and it was rolled back before release. It has been the
behaviour since and Apple treats it as intended.

Two consequences, one in each direction:

- **The seed is worth less on reinstall than on a new device.** A
  reinstall already keeps its token, and `connect(toAddress:)` already
  skips pairing when it finds one, so the seed is saving the address
  only. The full pairing skip is worth its most on genuinely new
  hardware.
- **But reinstall is the fastest case, not the slowest.** The seed is
  itself a Keychain item, so it survives deletion too and is already
  sitting there locally on relaunch. No iCloud round trip, no
  propagation wait, none of the timing risk that a brand new device
  carries.

Noted in passing, neither caused by this feature nor a blocker for it:
deleting Cabinet does not get rid of the RomM token, which stays on the
device until a factory reset. Normal iOS behaviour, and the token is
revocable server side, but "I deleted the app" is not the same as "I
signed out" and some people will assume it is.

## Q1. A seed whose token is dead

**One rule: a seed that does not fully validate becomes a prefilled
address field, silently.** No error, no scary state, no dead end.

Validation, before anything appears on screen:

1. Build `RommClient(baseURL: pairedAddress, accessToken: token, localURL: secondAddress)`.
   This is deliberate reuse. That client's existing preference and
   fallback machinery already tries the local address first when it is
   the local looking one and falls back on its own, so validating this
   way needs no new routing code and proves the token against whichever
   address the TV would actually end up using.
2. Call `currentUser()`.
3. A success shows the offer card, with the username from the response
   rather than the one cached in the seed.
4. A 401 or 403 means the token was revoked server side. Fall through.
5. A network failure means nothing at all is proven, so also fall
   through. Offering "Continue as marcus" and then failing is worse than
   never offering.

Falling through means the address field is prefilled with `pairedAddress`
and the screen behaves normally from there. That is a real consolation
prize rather than a fallback of last resort: typing a server address on
an Apple TV keyboard is the worst part of setup, and this skips it even
when the token is useless.

The TV never deletes a dead seed, because the TV never writes. The phone
repairs it the next time it pairs.

## Q2. Signing out does not clear the seed. Forgetting the server does.

Cabinet already has the two verbs and their meanings are already right.
`signOut()` deletes the token and keeps the address, so pairing again is
one step. `forgetServer()` is back to a fresh install. Map the seed onto
the verb that already means erase this pairing from my life.

- iOS "Unpair" (`signOut`) leaves the seed alone.
- iOS "Forget server" (`forgetServer`) removes that host's entry.

tvOS's Settings has one button, labelled "Sign out", which calls
`forgetServer()`. It does not matter here either way, since the TV never
writes the seed.

Worth being explicit about what this means: the seed keeps its own copy of
the token, so after Unpair on the phone, a brand new device can still
continue with a token the phone no longer holds. That is correct. Unpair
is a local convenience, not a revocation, and RomM has not invalidated
anything. Someone who wants the token genuinely dead revokes it on the
server, which lands in Q1's path.

## Q3. Confirm, never silent

Recommend a confirm step, and recommend it over the more magical option
on purpose.

- It is a TV, and the profile design already treats a TV as more than one
  person. A fresh TV silently signed in as whoever owns the Apple ID is
  the wrong default on a shared device.
- Q1's validation already fetched the username, so the card costs one
  screen and no extra round trip.
- Silent is unexplainable when it is wrong. A TV that is simply already
  signed in, to the wrong one of two servers, has no obvious way back.
  The card carries that escape hatch as a second row.
- This is a once ever screen. One click at setup is not friction worth
  optimising away.

## Q4. Multiple pairings, no longer accepted as a limitation

Decided 2026-08-15: hold a list. This reverses the earlier note, which
accepted last write wins.

The case is narrow. Cabinet talks to one server at a time, so this only
bites somebody who paired their phone to a second server and then set up
a new device: the new device would offer the second server and not their
own. Marcus's own read is that this will almost never happen, and the
decision to plan for it anyway is about not having to correct it later
rather than about the case being likely.

The fix is nearly free now and expensive later.

Holding a list rather than a value costs nothing in storage, and the seed
is already becoming a struct rather than a string to answer Q6. The only
real cost is UI, and it is one disclosure row on the card that appears
only when there is more than one entry. Doing it later means migrating a
synced format, which is the one migration shape this project has not had
to do yet and the hardest one to get right.

Known edge, not worth solving: entries are keyed by host, so pairing the
same server twice under two different accounts collapses to one entry.
Last write wins there, which is fine.

## Q6. The seed carries both addresses

This is the question that came out of the LAN work, and the framing needs
one correction before the answer.

The worry was that the seed comes from a phone, a phone's address is
almost certainly the public one because a phone has to work away from
home, and so this feature would systematically produce public address
Apple TVs and quietly undo LAN preference. The correction is that the
counterfactual is not a well configured TV, it is a person typing an
address into a TV. Someone types the local address only if they know it,
and the LAN memory already concluded that in practice only the server
owner knows it. So:

- A server owner pairing a TV by hand types the local address. A server
  owner whose seed carries both addresses gets the same outcome, because
  the existing preference logic picks the local one at home. Parity.
- Anybody else types the public address by hand, and gets the public
  address from a seed. Also parity.

So carrying both addresses is exactly what is needed, and it is enough.
It is not a partial fix with a hole in it. The remaining case, a phone
that never configured a second address, is not a hole this feature opens
and not one it can close: there is no local address anywhere on that
person's account to pass on.

Checked against all four setup shapes the LAN work handled:

| Phone's pairing | Seed carries | TV ends up on |
| --- | --- | --- |
| Public paired, local second | both | local at home, correct |
| Local paired, no second | local only | local, correct, and ideal for a TV |
| Local paired, public second | both | local at home, correct |
| Public paired, no second | public only | public, same as typing it by hand |

### The inconsistency this uncovered, latent rather than live

`Session.localServerURL` is device global. `TVProfile` has no local
address at all. And `Session.activateProfile` calls `restore()`, which
reads the local address key unconditionally, so switching profiles on a
TV keeps whatever local address was already set, no matter which server
the new profile points at.

**Corrected 2026-08-15, after an earlier draft of this section overstated
it.** This cannot be reached today, and the seed does not change that.
`TVAddProfileView` deliberately has no address step: its own comment says
a second profile "pairs a different account against that same server,
never a different one." So every profile on an Apple TV is on one server
by design, and one shared local address is the correct one for all of
them. The seed does not create the multi server case either, since it
only fires on a TV with zero profiles and so establishes the single
server every later profile pairs against.

What follows is therefore the shape of the problem if profiles ever span
servers, which is groundwork for joining other servers rather than a
defect anybody can hit. Kept on that basis, Marcus's call: it costs
nothing and reverting it gains nothing.

Were it reachable, it would go like this. A seeded TV
would hold profile A's LAN address globally; add a household member's
profile on a different server, switch to it, and its requests prefer
profile A's address. The heartbeat probe passes, because it really is a
RomM server, and then every real request 401s. That is exactly the failure
`setLocalAddress` grew its `/api/users/me` check to prevent, and
`activateProfile` has no equivalent.

The fix is to treat the local address the way the token is already
treated, per profile and copied into the shared slot on activate:

- `TVProfile` gains `var localServerURLString: String?`.
- `Session.activateProfile` gains a `localURL: URL?` parameter and writes
  or clears the key alongside the token.
- `TVProfileStore.activate` passes the profile's own value.

This is worth doing on its own merits, independent of the seed.

Migration for it is free but should be stated rather than assumed: adding
an optional property to a `Codable` struct decodes old stored JSON fine,
because the synthesized decoder uses `decodeIfPresent` for optionals, so
existing profiles come back with nil and behave exactly as they do today.

### One thing deliberately skipped

Adopting a seed writes the second address straight into the key rather
than going through `setLocalAddress`, which would re-validate it. That is
fine: it was validated on the phone when it was typed, and Q1's
`currentUser()` check already proved this token works over whichever of
the two addresses the routing preferred.

## Q5. Nothing has touched a device, so here is the test plan

This is more device bound than usual. Simulators do not participate in
iCloud Keychain in any way worth trusting, and the gate is literally a
device with zero profiles, so every case below means a real delete and
reinstall on real hardware.

1. Phone paired public plus local second, fresh TV. Card appears, adopting
   it lands the TV on the local address at home. This is the whole point
   of Q6 and should be checked by confirming the TV is actually on the
   local route, not just that it works.
2. Phone paired public, no second. Card appears, TV lands on public. No
   crash, no empty second address written.
3. Phone paired, token then revoked in RomM's own UI, fresh TV. No card,
   address prefilled, no error text anywhere.
4. TV with airplane mode at first launch. No card, address prefilled or
   empty, no error.
5. TV already carrying a profile. Nothing appears at all, ever.
6. Propagation. Launch a fresh TV immediately after pairing a phone and
   watch how long the card takes to appear. Marcus's own note is that
   iCloud Keychain propagation is seconds to sometimes longer, and this
   is the part most likely to need a round of correction.
7. Two servers in the seed, fresh TV. The disclosure row appears and
   picking the second one works.

Case 6 is why the offer card polls rather than reading once. Keychain sync
has no public change notification, so the screen re-reads on an interval
while it is up.

**Decided 2026-08-15: once anything has been typed into the address
field, the card never appears.** A seed landing twenty seconds into a
fresh setup would otherwise shift the layout and move focus while
somebody is mid word with a remote, to save them the last few characters
of an address they were already most of the way through. Stop polling at
the first keystroke.

## On the data migration rule

The 2026-08-14 note took a deliberate, time limited exception to the data
migration rule, on the grounds that nobody had installed a real build yet.
That exception is not needed here and the question of whether it lapsed
does not apply to this feature.

The seed is a brand new Keychain item, so there is no existing data on
anybody's device to preserve, whoever has installed what. The only
existing format this touches is `TVProfile`, and adding an optional
property to it decodes old stored profiles as nil, which is already the
non destructive path.

The versioned seed format above is not a migration path for existing
users either. Its reason is future Cabinet versions running on the same
person's other devices at the same time.

## Deliberately not done

**The TV never re-reads the seed after first run.** Raised on
2026-08-15: an Apple TV whose server's local address has moved, after a
DHCP reshuffle, is stranded with a dead address and no fallback, and the
seed could in principle refresh it. Ruled out. Marcus's call is that
anyone running a RomM server should be assumed to have given it a static
IP or a reservation, and Cabinet already accepts `.local` names too,
which sidesteps DHCP entirely. Reopening the first run only boundary for
a problem with a free and standard fix is a bad trade.

Keep this separate from the per profile bug under Q6. A static IP fixes
an address that moved. That bug is about two different servers, where the
address never moved and is still perfectly valid, just not for the
account now using it.

## Other ways to do this, considered 2026-08-15

Only one thing actually needs solving: how a device that knows nothing
learns the server address, and ideally a token with it. Everything below
was weighed against the seed.

- **A QR handoff. Tested against the live server 2026-08-15, and it
  loses.** The idea: the Apple TV shows a code carrying its own local
  address and a one time secret, you scan it with the phone you are
  already using to approve pairing, and the phone sends the server
  address over and approves the TV's own pairing through the API. No
  browser, no propagation wait, no dependence on an iCloud setting.

  It is genuinely possible. `/api/auth/device/approve` exists and does
  accept a bearer token rather than requiring a browser session. RomM
  5.1 also ships its own QR pairing, the `/api/client-tokens` family
  with pair, exchange and status endpoints, which is the thing an
  earlier session flagged as worth checking.

  **But both routes require the `me.write` scope, which Cabinet does not
  request.** Verified rather than inferred: the same token returns 200
  on both `me.read` endpoints and 403 on both `me.write` ones,
  `/api/auth/device/approve` and `POST /api/client-tokens` alike. The
  server describes that scope as "Modify your profile."

  Two costs, and together they settle it. It is far broader than setup
  needs, and adding a scope forces every existing pairing to pair again,
  the precedent `RommScopes.required` already documents for
  `collections.write`. Asking for permission to modify somebody's RomM
  profile so an Apple TV can skip a step is worse than the step. The
  seed needs no new scope and no forced re-pair.

  Revisit only if RomM ever narrows this, for example a scope that can
  approve a device without touching the profile.
- **Bluetooth.** Possible, pointless. An Apple TV always has a network,
  and without one Cabinet cannot reach RomM anyway.
- **A QR the TV scans.** Impossible, a TV has no camera. QR only ever
  works TV to phone, which is what pairing already uses it for.
- **Scanning the LAN for a RomM server.** Ruled out. It is a port scan,
  it is slow, and it is rude.
- **Leaving it alone.** tvOS already offers your iPhone as a keyboard for
  a focused text field, so typing the address is less painful than it
  sounds. But the seed carries the token as well, so it removes the code,
  the QR, the browser and the approval too, not just the typing. Judged
  worth more than "you do not type a URL," which is what nearly talked us
  out of it.

## When iCloud Keychain is switched off

The seed never leaves the phone and every device shows today's plain
address screen. No error, nothing to explain, it simply does not happen.

Worth knowing that this is not rare among the people Cabinet is for.
Somebody running their own password manager has often turned that sync
off deliberately, and that is the same self hosting crowd that runs RomM.
There appears to be no API to ask whether it is on, so Cabinet cannot
prompt about it either. Confirm that before relying on it.

**This is reduced coverage, not a defect, and it should not be treated as
one.** Marcus's call 2026-08-15, and it corrects an overstatement of mine:
the feature silently doing nothing is the correct behaviour, and nobody
is worse off than before it existed. It is not a reason to prefer the QR
handoff up front. Build the cheap thing, and if coverage turns out to
matter, the handoff can come later for exactly the people this missed.

## Phase two, if it ever earns it

Parked 2026-08-15. Worth writing down because it was worked out properly
and the reasoning will not survive otherwise.

The idea: widen the seed from a pairing into a **backup**, so a fresh
install also gets your settings back. Not sync. Written when something
changes, read only when a device finds itself empty, which is the same
gate and the same first run only boundary the seed already has. After
that the devices drift, and that drift is exactly what separates this
from syncing.

**Controller mappings are the case that justifies it.** `ControllerRemapView`
exists on both platforms, and `ControllerBindings` stores per controller
model in UserDefaults, so it is device local today. The property nothing
else on the list has: the same physical pad moves between your devices.
Spend time getting the arcade six button fold right on your phone, pick
the same pad up in front of the Apple TV, and it is back to defaults. A
shader belongs to a screen, a controller belongs to you. `MenuHotkey` is
the same shape. Shaders are per platform and one tap to change, tvOS glow
is tvOS only, touch layouts are iOS only, and tvOS profiles belong to
that TV rather than to you.

**Mappings are not tied to a server**, so they would restore silently on
a fresh install with no card and no Continue press, whether or not the
pairing offer is taken and even against a different address. Pairing gets
asked about because it is identity. Settings do not.

**The household problem, and Marcus's answer to it.** An Apple ID covers
a household. If two Apple TVs both write into one shared blob, a change
made on a child's TV becomes everybody's defaults on the next install.
The pairing half fixed the equivalent hazard by letting only the phone
write, and that fix does not work here, because mappings genuinely do get
set on a TV.

Marcus's model, 2026-08-15, and it is cleaner than storing one blob:
**every device publishes only its own settings, and a fresh device copies
from one of them to get started. From that point on the devices are
independent.** Nothing ever merges, so there are no conflicts to resolve
at all, and a child's Apple TV cannot leak into anybody else's defaults
because copying is a choice somebody makes. Same model Apple's own device
setup uses.

It also handles reinstall with no extra thinking. Delete and reinstall on
the same Apple TV and that device's own slot is still there, so it
restores itself with nothing to choose. A picker only ever appears on a
genuinely new device.

**One practical catch, and the decision on it.** Since iOS 16 an app
cannot read the user assigned device name without an entitlement Apple
has to grant on request, so it just gets back "iPhone" or "Apple TV". Two
Apple TVs in one house would be indistinguishable in a picker. Cabinet
would probably qualify for that entitlement, since the justification is
honest, but it means applying to Apple and carrying it permanently for a
label in a picker in a parked feature. **Skipped, Marcus's call
2026-08-15.**

Distinguish devices by model plus when their settings were last updated,
nothing else. "Apple TV, updated 2 hours ago" against "Apple TV, updated
three weeks ago" separates them in practice, needs nothing from Apple,
and needs no naming screen or stored label. Two TVs both updated today
would be ambiguous, which is fine: this picker appears once, on a new
device, and every setting it copies is editable afterwards.

Worth confirming the entitlement rule still holds whenever this is picked
up.

Reason for parking: the pairing half is small and well understood, this
half has a household problem it does not share, and there is no confirmed
need yet. Note this is the second time iCloud settings sync has been
parked for want of a real need.

## Status

Phase one, the pairing seed, is fully designed. Phase two is parked.
All six original open questions are answered. Nothing here is built and nothing
has touched a device, so the test plan under Q5 is the next real step.
