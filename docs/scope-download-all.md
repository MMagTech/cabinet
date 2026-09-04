# Download All, scope

Status: built for the Mac 2026-09-02, for iOS 2026-09-03. tvOS does not
offer it; a television keeps a handful of games and has the disk for
that. Neither build has shipped in a release yet.

## What it is

One action per platform that keeps every game the store can keep, the
way Music downloads an album rather than a song at a time. The
confirmation states the count and the total size first (RomM gives
`fs_size_bytes` per rom, so the sum is free), refuses plainly when the
disk cannot hold it, then the queue runs without ceremony and shows
progress where it was started: the menu item itself reads "Downloading
12 of 66…" with Cancel beneath it, every cover in flight wears its
ring, and a status line sits where each platform keeps one, the
sidebar's foot on the Mac and the top of Storage on the phone. Cancel
stops the queue and keeps what finished. A background-only notification
reports the end, per Apple's guidance that a result the person is
looking at is shown in place, not announced.

The gate is keepable, not playable: an unsupported platform's files are
still worth having for another emulator, which is already how a single
download works. Only the Mac's Downloaded sidebar count stays on the
playable rule, since that screen launches games.

## Where it lives

The coordinator, the confirmation and the menu items are one shared
file, `DownloadAll.swift`, and the queue itself is
`KeptGameStore.keepAll`, which walks the list and awaits each game
through the same `performKeep` a single Download uses, so the ring, the
error text and the Downloaded count behave exactly as for one.

- Mac: the platform's context menu on the sidebar row and the Library
  tile (Download All…, Remove All Downloads…, Show in Finder), a button
  beside the platform title, and File > Download All….
- iOS: the platform screen's toolbar menu, under the view picker, and a
  long press on a Library tile. Remove All Downloads… sits beside it.

## The phone's transfers

A download that dies when the screen locks is no way to bring down a
platform, so on iOS every kept game's ROM comes through one background
`URLSession` (`BackgroundDownloads.swift`), the system carrying the
transfer in its own process. Apple's page for
`background(withIdentifier:)`: transfers "continue even when the app
itself is suspended or terminated", and if the system quits the app it
is relaunched to collect the results. The whole platform's ROM
transfers are handed to the system up front, so it works through the
list while the app sleeps; the store's queue then finishes each game,
firmware, newest state, in-game save and manifest, as its file lands.
Those finishing fetches are small and stay on the ordinary session; a
finish that fails once is tried again before the game counts as failed,
since the app may have been put to sleep between the file landing and
the manifest being written.

Wi-Fi only, and no setting for it. Apple's `waitsForConnectivity` page
says background sessions "always wait for connectivity", so a request
that refuses cellular waits for Wi-Fi rather than failing; the
confirmation says "Wi-Fi only", or "Waits for Wi-Fi" when the phone is
on cellular at that moment. A single Download from a game's own screen
goes over whatever connection there is, as it always has: a person
tapping one game wants it now.

What was confirmed is written down (`download-all.json` in Application
Support) when the queue starts and removed when it ends, so a launch
after the system quit the app mid-queue picks the queue up where it
stopped; transfers already handed to the system are found again by
their task descriptions. A person force-quitting the app cancels the
system's transfers, per the same Apple page, and the record then
restarts what is missing at the next launch.

The Mac downloads in the foreground and needs none of this; its lines
in the store are byte-identical to before.

## The phone's Live Activity

While a queue runs, the phone shows it where iOS shows live progress:
the Dynamic Island (icon and "12/66" compact, name and bar expanded)
and the Lock Screen (name, count, bar). Apple's Live Activities page
sets the shape: every presentation must be supported, an activity may
run for eight hours, and it must be ended with its final content and a
dismissal policy. Cabinet ends it with the final count, "downloaded"
or "stopped" for a cancel, and leaves it on the Lock Screen for
fifteen minutes. Updates are coalesced to one a second, since Apple
budgets how often an activity may change. The shared type lives in
`DownloadActivity.swift`, compiled into both the app and the widget
extension; the views are `DownloadActivityWidget.swift` in the
extension; the app side is `DownloadLiveActivity` in DownloadAll.swift.
iOS asks the person to allow Live Activities from the app the first
time one starts.

## Open

- A hardware pass on a real iPhone: lock the phone mid-queue, leave the
  house on cellular, come back. The simulator proves the queue and the
  relaunch, not the radio.

Decided 2026-09-03: the Mac's Downloaded screen keeps listing only the
platforms Cabinet can play. Games kept from an unsupported platform are
on the disk and in the Finder mirror for another emulator, which is
their whole purpose, and listing them on a screen whose action is Play
would not improve anything.
