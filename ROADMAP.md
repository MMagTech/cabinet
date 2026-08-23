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

- **Your phone as the controller for a game on the television.** The
  Apple TV runs the game, your phone becomes its control panel, and for
  the arcade cabinets that means the real thing: a spinner you roll, a
  trackball you flick, a wheel, pedals, a light gun. Two people with two
  phones would be two players.

  This one is built and works, verified across a full day on real
  hardware, and ships to nobody because there is no authentication on the
  wire yet. Anything on your network could drive your television
  mid-game, which is fine in a house and not fine in a release. The
  design for fixing it is written up in
  [docs/scope-phone-controller-pairing.md](docs/scope-phone-controller-pairing.md):
  pair a phone to a television once with a code shown on screen, the same
  way Cabinet already pairs to RomM, and every later packet proves it.

- **A controller that needs no account at all.** Cabinet shows you
  nothing until it is paired to a RomM server, so a friend who comes over
  with a phone cannot join a game on your television even though the
  controller half needs nothing from RomM.

  The idea is a mode where you install Cabinet, skip setup entirely, and
  the app is a controller and nothing else. It is less app rather than
  more: no library, no downloads, no saves. It would turn "my kid can
  play" into "anyone in the room can play", and it is why the pairing
  design above deliberately does not lean on RomM identity, since a guest
  has none.

- **A companion screen for iPhone, over AirPlay or wired HDMI.** An
  iPhone can drive an external display with content different from what
  is on the phone itself, the same trick Apple's own Photos app uses.
  The idea: gameplay renders on the TV at its proper aspect and fills
  the screen, while the phone becomes a full-screen control panel with
  room for real buttons rather than gutters beside the picture.

  Wired needs DisplayPort, which most current iPhones have but the
  iPhone Air, 16e and 17e do not. AirPlay has no such restriction and
  works with any AirPlay 2 television, which many recent Samsung, LG
  and Sony sets have built in, so it reaches people who own no Apple TV
  at all.

  The obvious objection was latency, and a first test says it is not
  the problem it looked like: mirroring to an AirPlay 2 set over Wi-Fi
  played Deathsmiles, a bullet hell game and the heaviest thing in the
  test library, without it getting in the way. That was plain mirroring,
  which is the pessimistic case, since a real external-display path
  sends the television the game alone instead of a letterboxed copy of
  the phone screen.

  Deliberately scoped small if it happens: the gameplay view moves to
  the TV and nothing else. No port of the ten-foot interface, no focus
  navigation, since a touchscreen needs no focus engine. Native cores
  only at first; a web player on an external display is its own
  question. The fiddly part is disconnecting mid-game, which should
  bring the picture back to the phone rather than strand the player.
- **More systems, running natively.** Cabinet compiles nineteen
  emulators into the app, and each new one is a core to build plus a
  control layout to draw. Four of the seven originally listed here are
  done: Atari 2600, Vectrex, 3DO and Virtual Boy.

  What is left, and the honest state of each:

  | System | Core | Notes |
  |---|---|---|
  | ColecoVision | Gearcoleco | Ready to go, but needs its BIOS on your server first |
  | Intellivision | FreeIntv | Its disc controller and keypad are the hard part |
  | Magnavox Odyssey<sup>2</sup> | O2EM | Keyboard-adjacent controls |
  | Philips CD-i | SAME_CDI | Experimental upstream, lowest priority |

  Two more were looked at properly and are worth recording. **Nintendo
  DS** is a real candidate: its cores build for Apple platforms with no
  just-in-time compilation at all, and Mario Kart DS measured 4.1ms a
  frame mid-race against a 16.7ms budget, so speed is not the obstacle.
  The interface is: two screens and a stylus. **Atari Jaguar** was
  declined rather than deferred. The core is in much better shape than
  its reputation, but the console only ever had 63 licensed games, which
  is a small return for a controller with a twelve-key keypad to solve.

  Beyond those, the runway is genuinely short. Almost everything left in
  a normal library, PlayStation 2, GameCube, Wii, 3DS, Switch, PSP,
  Vita, needs runtime code generation that Apple does not permit, or
  hardware beyond what an interpreter can carry.

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
  of all, on Apple TV especially. This is much better than it was, and
  the cause is understood rather than mysterious: see
  [issue #6](https://github.com/MMagTech/cabinet/issues/6) for the full
  root cause. Normal play now holds 60fps with clean audio, which it
  could not do at all before, and the console's many 2D shooters and
  fighters play well. Heavy 3D titles still drop in their busiest
  moments. The remaining limit is that the Dreamcast's CPU has to be
  interpreted rather than translated, because apps on Apple's platforms
  cannot generate code at runtime, and the settings that would buy speed
  back are already at their fastest usable values.

- **PC Engine's 2-button vs. 6-button controller mode** isn't wired up
  to its touch layout yet, even though the core supports it.
- **PS1 and Saturn multi-disc games aren't supported**, and whether they
  should be is genuinely undecided, it would need real `.m3u`-style disc
  swapping support, not just a missing feature flag.

- **iCloud sync for settings.** No confirmed real need yet.
