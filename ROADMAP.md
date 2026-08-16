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

- **In-game saves, on every platform that has them, on both iPhone and
  Apple TV.** Saving inside a game used to work while you played and
  vanish when the game closed, on everything except PlayStation, Nintendo
  64 and Dreamcast. Now Game Boy Advance, SNES, NES, Game Boy, Game Boy
  Color, Genesis, Master System, Game Gear, 32X, TurboGrafx CD, Saturn,
  Sega CD and Neo Geo Pocket all keep their saves, back them up to RomM,
  and put them back the next time you play, including on a different
  device: save on the phone, carry on from the couch. Sega CD's external
  RAM cartridge is kept as well, since games prefer it when it is there,
  and the Game Boy's clock travels alongside its save for the games that
  depend on it. Sega CD, Neo Geo Pocket and arcade only commit their
  saves when you quit properly, which is how those emulator cores work
  rather than a choice, so a session ended by iOS killing the app in the
  background can still lose what you did since launch.

- **Your recent games on the Apple TV's top shelf.** When Cabinet sits in
  the top row of the Apple TV home screen, the large area above it now
  shows the games you played recently, with their own cover art.
  Selecting one opens it, where your save states are; pressing Play on
  the remote drops you straight into the game. Only games this Apple TV
  can actually run appear there, and it shows nothing at all until you
  have paired and played something, rather than putting a row of dead
  ends on your home screen.

- **Cartridge motion sensors on iPhone.** A few Game Boy Advance games
  shipped with hardware inside the cartridge. WarioWare: Twisted! has a
  gyroscope and is played by physically turning the thing in your hands,
  and until now Cabinet had no answer when the game asked which way you
  had turned it, so it stopped being playable at the first prompt. The
  phone's own motion now stands in for that cartridge, which is rather
  better hardware for it than the original ever had. Yoshi's Universal
  Gravitation and Koro Koro Puzzle's tilt sensors work the same way.
  iPhone only: the Siri Remote has had no motion sensors since 2021.

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
- **Dreamcast runs below full speed in heavy scenes**, cut scenes worst
  of all, on Apple TV especially. The Dreamcast core has to interpret
  every instruction rather than translating it, because apps on Apple's
  platforms cannot generate code at runtime, and video-heavy scenes are
  the hardest case for that. The usual emulator settings that would buy
  speed back are already at their fastest values here, so the ceiling is
  mostly real rather than a matter of tuning.
- **PC Engine's 2-button vs. 6-button controller mode** isn't wired up
  to its touch layout yet, even though the core supports it.
- **PS1 and Saturn multi-disc games aren't supported**, and whether they
  should be is genuinely undecided, it would need real `.m3u`-style disc
  swapping support, not just a missing feature flag.

- **iCloud sync for settings.** No confirmed real need yet.
