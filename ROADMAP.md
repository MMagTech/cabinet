# Roadmap

Where Cabinet is headed. This is not a changelog, see
[Releases](https://github.com/MMagTech/cabinet/releases) for what has
already shipped. Nothing here is a promise or a deadline, this is a
weekend project worked on as time allows, but it is the real direction,
not a wishlist that gets ignored.

If something here interests you, or you want to pick one up, open an
issue or a discussion first so the approach can be talked through before
any code gets written.

## Being explored

Not committed, not scoped, real conversations that happened and are
worth having in the open.

- **More systems, running natively.** Cabinet compiles twenty-two
  emulators into the app, and each new one is a core to build plus a
  control layout to draw. Everything originally listed here is done:
  Atari 2600, Vectrex, 3DO, Virtual Boy, Nintendo DS and Game & Watch,
  plus PSP, which this file previously listed as impossible.

  What is left, and the honest state of each:

  | System | Core | Notes |
  |---|---|---|
  | ColecoVision | Gearcoleco | Ready to go, but needs its BIOS on your server first |
  | Intellivision | FreeIntv | Its disc controller and keypad are the hard part |
  | Magnavox Odyssey<sup>2</sup> | O2EM | Keyboard-adjacent controls |
  | Philips CD-i | SAME_CDI | Experimental upstream, lowest priority |

  Beyond those the runway is genuinely short, and shorter than it looks,
  because PSP was on the wrong side of this list until it shipped.
  PlayStation 2, GameCube, Wii, 3DS, Switch and Vita all need runtime
  code generation Apple does not permit, or hardware beyond what an
  interpreter can carry. PSP turned out not to: PPSSPP's own interpreter
  is fast enough without it, which is upstream's claim and now Cabinet's
  measurement too. That is worth remembering before writing anything
  else off.

- **A native touch control restyle.** The current on-screen controls are
  functional but read a little flat next to the rest of the app. A
  restyle direction has been discussed, not built.
- **A real loading screen on tvOS for large downloads.** Right now the
  Play button's own label just turns into a percentage while a native
  game downloads, on a short game that can flash by in under a second.
  The idea is a proper full-screen moment for genuinely large
  downloads, small ones would keep today's quick inline behavior. Not
  settled whether to build it at all, let alone how.
- **PS1 and Saturn multi-disc support.** Genuinely undecided rather than
  merely unbuilt, it would need real `.m3u`-style disc swapping, not just
  a missing feature flag, and nobody has weighed whether that's worth
  carrying.
- **Settings syncing across your devices via iCloud.** No confirmed real
  need yet, just an idea that comes up alongside the pairing work above.
- **A widget, and opening at a game from outside the app.** A home
  screen widget showing what you were playing, and Spotlight results that
  go straight into a game, both need the same missing piece: Cabinet can
  open at a fixed destination but not at a particular game. Quick actions
  prove the launch path works; what does not exist is a way to say which
  game. Build that once and both become small. Worth doing together for
  that reason rather than separately.
- **Light guns on the console systems.** The gun works on the arcade
  cabinets, and the aim it uses lives entirely in the phone and knows
  nothing about which core is running, so the console systems inherit it
  for free. What is missing is games to point it at. Research on which
  cores take a gun and on which port is already done.
- **Finding a game from the phone's own search.** Cabinet could hand iOS
  an index of the library, so typing three letters into Spotlight brings
  up the game with its cover art and takes you straight there without
  opening the app first. With hundreds of games that is a faster way in
  than any list, and the pieces are mostly already here: the covers are
  cached on device and the RomM sync is the natural place to keep the
  index current. Keeping it honest is the actual work, since a search
  result that opens a game the server no longer has is worse than no
  result. iPhone only; the Apple TV top shelf is already this idea in the
  television's own idiom. The open question is what a result should do
  when the game is not downloaded yet, because silently starting a
  gigabyte download from a search result is a poor surprise. Low priority.

A few ideas got explored just as seriously and reached a real answer
instead of an open question. Those live in
[docs/settled.md](docs/settled.md) rather than here: a native macOS build,
uploading a ROM from Cabinet, Atari Jaguar as a native core, and skipping
setup on a new device via iCloud.

What Cabinet doesn't do today, rather than what it might do next, is in the
[README](README.md#what-doesnt-work-yet) instead of here.
