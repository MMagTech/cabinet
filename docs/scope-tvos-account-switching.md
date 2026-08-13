# tvOS account switching

Status: shipped 2026-08-12, commit 5aa6995.

## Why

An Apple TV is naturally a shared household device in a way an iPhone is
not. Someone might want to switch between their own RomM login and a
shared family one regardless of which system-level Apple TV user is
active, and two different Apple TV users might legitimately want to share
one RomM login. Those are two separate axes of identity, and treating
them as the same thing gets both wrong.

## Why in-app profiles, not tvOS's own multi-user

tvOS has a real system-level multi-user entitlement
(`TVUserManager`/"Runs as Current User"), and the obvious first idea was
to hang RomM accounts off of it. Ruled out for a concrete technical
reason, not a stylistic one: tvOS's per-user containers would partition
this app's shared ROM cache per system user. A ROM is not user-specific,
the same Dreamcast disc is the same bytes no matter who launched it, so
system-level containers would mean every person on the household's Apple
TV redownloads the same file into their own isolated copy. In-app
profiles share one cache and keep only credentials and preferences
separate per profile, which is also strictly better on a platform that
gives an app only 500KB of real persistent storage and expects everything
else to be purgeable.

## What ships

`TVProfile` (`TVProfileStore.swift`): a label and a full server URL per
paired account. Deliberately not reachable from any iOS code and does not
touch `Keychain.swift`'s existing single-account storage format at all,
phones are one person, so this does not exist on iOS. Each profile's
token lives in its own Keychain entry keyed by the profile's id, not by
server host the way the shared login flow already works, since two
profiles on the same RomM server would otherwise collide on that key.
Switching profiles copies the chosen one's token into the shared slot
`Session` actually reads from, then reloads `Session` from it; nothing
downstream needs to know profiles exist at all.

Lives in Home's top-right corner (`TVAccountChip`), the real RomM
username and avatar once fetched, a generic person glyph before that or
if the avatar file was purged from cache. Tapping it opens
`TVAccountSwitcherView`: every paired profile as a row, an Add Profile
row at the bottom, the active one marked and disabled rather than
re-selectable.

Adding a profile never asks for a server address a second time. The
household's first profile already established one through the normal
setup flow, so `TVAddProfileView` pairs a new account against that same
known server, through its own standalone `RommClient` rather than the
live `Session`, so adding a second profile mid-session cannot reset the
app back to setup screens out from under whoever is already signed in.

Switching can optionally require a PIN (`TVAddProfileView`'s sibling,
`TVSetPINView`, and the gate itself, `TVPINEntryView`), off by default. A
full-screen focus-navigable number pad, not `.alert` with a `SecureField`,
tvOS alerts have no on-screen keyboard a remote can drive, so a native
numeric keypad is the real tvOS convention here, the same reasoning that
already shaped PIN-style entry elsewhere in tvOS apps generally.

A real lesson from building this, worth keeping: `fullScreenCover` paints
no opaque backdrop of its own on tvOS, so without an explicit one the
screen underneath, Home or Settings, shows straight through and the two
read as one garbled screen. `TVGameLaunchView` had already learned this
once; missed again here on first pass, now fixed with the same
`.tvModalBackdrop()` treatment.

## Resolved from the original design discussion

Two questions were explicitly left open when this was designed. Both are
answered by what shipped: PIN protection is real but optional, not a
forced choice between friction and none. And this does not exist on iOS,
confirmed in `TVProfileStore`'s own doc comment, a phone is one person.

## Out of scope, explicitly

- Any iOS-facing UI. The underlying idea, one physical device holding
  several RomM logins, is tvOS-shaped specifically because a TV is
  shared and a phone is not.
- Syncing which profile is active across multiple Apple TVs in the same
  household. Each device's active profile is its own local state.
