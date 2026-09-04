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

- **More systems, running natively.** Cabinet compiles twenty-three
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

- **Download a whole platform on the Mac.** A phone keeps a handful of
  games; a desk machine has the disk for all of them. The idea is a
  single action on a platform, "Download All", that keeps every game
  the Mac can play from that system, the way Music downloads an album
  rather than a song at a time. It would say the count and the total
  size before it starts, queue the files one after another rather than
  all at once, and stay cancellable. It would take every game Cabinet
  can keep, playable here or not: an unsupported platform's files are
  still worth having for another emulator, which is already how a
  single download works. Built for the Mac the same day it was noted,
  2026-09-02, and for the phone the day after: there the files come
  down through the system's own background downloader, over Wi-Fi
  only, so a platform started at the table finishes with the phone
  locked in a pocket, and a queue the system quit the app in the middle
  of carries on at the next launch. Both waiting on a release.
- **Play Together, two screens.** Two or more devices each running the
  same game, with only the button presses crossing the house Wi-Fi,
  so each person plays on their own screen: two phones with no
  television, two rooms, a friend on a hotspot. A maybe, deliberately.
  Two people on one screen already works, a TV or a Mac running the
  game with phones as the controllers, and that covers most game
  nights; this adds the two-screen case at the cost of the largest
  piece of work on this list and a mechanism that stays delicate after
  it ships, since a dropped packet pauses everyone and only the cores
  that compute identically on two machines can take part. The design
  is settled if the need arrives: seats rather than two players, the
  existing pairing wire as the transport, lockstep with a short input
  delay, and a "syncing players" beat when two machines fall out of
  step. Decided 2026-09-04 not to build ahead of a real need.
- **Picture tiers per machine.** The picture settings that hold sixty
  frames on the fastest Mac here were tuned there, and a slower machine
  drops frames on the same settings. The idea is three named bundles of
  settings, Performance, Balanced and Quality, and a way for each machine
  to land on its own: measured once in the lab for machines in the room,
  and for any other machine a half minute of watching its own frame
  times the first time a heavy core runs, stepping down or up and
  remembering the answer for that chip. A chip nobody has met yet, next
  year's, would simply stay at Quality unless it had to step down.
  Explored 2026-09-03 and deliberately not built: it would sit in the
  launch path every core shares, and there is no machine here that is
  either too slow at the defaults or wasting headroom to test it
  against. It gets built when one exists.
- **A native touch control restyle.** The current on-screen controls are
  functional but read a little flat next to the rest of the app. A
  restyle direction has been discussed, not built.
- **Light appearance on the screens that carry ambient art.** Cabinet TV
  and Cabinet for Mac both draw a single backdrop behind everything, the
  cover of whatever you played last, blurred past recognition and
  darkened so text and glass always have a floor. That canvas stays dark
  no matter what the system appearance is set to, so switching macOS or
  tvOS to Light turns the chrome dark against a dark background and the
  text becomes hard to read. The Mac already avoids this by pinning
  itself to dark; the Apple TV does not, and follows the system today,
  which is where the problem is visible. There are two honest ways out
  and they lead to different apps. One is to commit to dark on both, the
  position the Apple TV app and Music's Now Playing already take, and
  accept that Cabinet ignores a system preference on purpose. The other
  is to give the backdrop a real light treatment, a bright washed
  version of the art rather than a darkened one, so both platforms can
  honour the setting. The first is a line of code and a decision, the
  second is a design piece that has to look right on a television and on
  a desk. Undecided. iPhone is not affected either way: its ambient
  backdrop is deliberately confined to the game launch screen, and the
  rest of its shell is ordinary iOS chrome that already follows the
  system.
- **A real loading screen on tvOS for large downloads.** Right now the
  Play button's own label just turns into a percentage while a native
  game downloads, on a short game that can flash by in under a second.
  The idea is a proper full-screen moment for genuinely large
  downloads, small ones would keep today's quick inline behavior. Not
  settled whether to build it at all, let alone how.
- **Multi-disc games.** Waiting on a real one. It would need `.m3u`-style
  disc swapping in the player, which the libretro cores already
  understand, and any disc system could meet it, PlayStation and Saturn
  most often. As of 2026-09-03 the library it is built against has no
  multi-disc game on any platform, so there is nothing to build it
  against or test it with. It gets built when one arrives, not before.
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
