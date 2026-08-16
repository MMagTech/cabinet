# Roadmap

Where Cabinet is headed. This is not a changelog, see
[Releases](https://github.com/MMagTech/cabinet/releases) for what has
already shipped. Nothing here is a promise or a deadline, this is a
weekend project worked on as time allows, but it is the real direction,
not a wishlist that gets ignored.

If something here interests you, or you want to pick one up, open an
issue or a discussion first so the approach can be talked through before
any code gets written.

## Built, waiting on a release

Done and working, just not in a tagged release yet.

- **Preferring the local network over the public internet.** Set an
  optional second address for your server, and Cabinet uses whichever of
  the two is on your local network whenever it can actually reach it,
  falling back on its own when it cannot. It works whichever box you
  typed which address into, so setting Cabinet up at home first and
  adding a public hostname later works as well as the other way round.
  Downloads stop being bottlenecked by your home connection's upload
  speed, and, if your home internet is metered, stop spending your
  allowance twice on bytes that never needed to leave the house. iPhone
  only for now, an Apple TV is set up with whichever address you pair it
  against.

## Being explored

Not committed, not scoped, real conversations that happened and are
worth having in the open.

- **A companion screen for iPhone over wired HDMI.** iPhones with
  DisplayPort support (most current models, notably not iPhone Air,
  16e, or 17e) can drive an external display with content different from
  what is on the phone itself, the same trick Apple's own Photos app
  uses. The idea: plug into any TV, gameplay renders there, the phone
  becomes a real second screen, cover art and browsing while idle, a
  "now playing" view during a game, closer to a console companion app
  than a remote. Layout and interaction are entirely undecided.
- **A native touch control restyle.** The current on-screen controls are
  functional but read a little flat next to the rest of the app. A
  restyle direction has been discussed, not built.
- **A real loading screen on tvOS for large downloads.** Right now the
  Play button's own label just turns into a percentage while a native
  game downloads, on a short game that can flash by in under a second.
  The idea is a proper full-screen moment for genuinely large
  downloads, small ones would keep today's quick inline behavior. Not
  settled whether to build it at all, let alone how.
- **Skipping setup on a new device: tried, and not happening.** The idea
  was that a brand-new Apple TV signed into the same Apple ID could pick
  up the pairing your iPhone already has, via iCloud Keychain, so you
  never type a server address with a remote. It was designed, built and
  taken to real hardware, where it did nothing: Apple TV does not
  participate in iCloud Keychain at all, so the seed can never arrive
  there. The iPhone-to-iPhone half did work, and was dropped anyway,
  because it meant quietly copying a token for your private server into
  iCloud in exchange for skipping one text field.

  Two alternatives were checked and rejected too. Approving the pairing
  inside Cabinet on your phone, the way Discord signs you in on a TV,
  needs a RomM permission scope that would also let Cabinet modify your
  account and mint API tokens. A direct phone-to-TV handoff over your
  own network is the only remaining route that removes typing the
  address, and it only works when both are at home. The reasoning is
  written up in
  [docs/scope-icloud-pairing-continuity.md](docs/scope-icloud-pairing-continuity.md)
  so it doesn't get proposed again from scratch.

## Known gaps

Real, acknowledged holes, not yet started.

- **Five platforms have no dedicated touch control layout**: Amiga CD32,
  Atari Jaguar, Neo Geo AES/MVS, Philips CD-i, Virtual Boy. They fall
  back to a generic layout today.
- **No native autosave.** Native play only resumes from an explicit save
  state, not automatically on quit or backgrounding, unlike the web
  player.
- **In-game saves are only kept on three platforms.** PlayStation,
  Nintendo 64 and Dreamcast save and restore properly. On every other
  native platform with save hardware, Game Boy Advance, SNES, NES, Game
  Boy, Genesis, Sega CD, Master System, Game Gear, 32X, TurboGrafx CD,
  Saturn and Neo Geo Pocket, saving inside a game works while you play
  and is lost when the game closes. Save states still work, which is
  what makes it easy to miss. Saturn is the worst of them, its saves
  currently have nowhere to be written at all. Atari 7800 and arcade
  are unaffected, neither had in-game saves worth keeping. The full core
  by core findings, including the traps involved in fixing it, are in
  [docs/native-in-game-saves.md](docs/native-in-game-saves.md).
- **PC Engine's 2-button vs. 6-button controller mode** isn't wired up
  to its touch layout yet, even though the core supports it.
- **PS1 and Saturn multi-disc games aren't supported**, and whether they
  should be is genuinely undecided, it would need real `.m3u`-style disc
  swapping support, not just a missing feature flag.

- **iCloud sync for settings.** No confirmed real need yet.
