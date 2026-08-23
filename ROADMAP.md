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
- **More systems, running natively.** Cabinet compiles eighteen
  emulators into the app, and each new one is a core to build plus a
  control layout to draw. Three of the seven originally listed here are
  done: Atari 2600, Vectrex and 3DO. Virtual Boy is built and running on
  a device, not yet shipped, waiting on one control verification before
  it lands.

  What is left, and the honest state of each:

  | System | Core | Notes |
  |---|---|---|
  | ColecoVision | Gearcoleco | Ready to go, but needs its BIOS on your server first |
  | Intellivision | FreeIntv | Its disc controller and keypad are the hard part |
  | Magnavox Odyssey<sup>2</sup> | O2EM | Keyboard-adjacent controls |
  | Philips CD-i | SAME_CDI | Experimental upstream, lowest priority |

  One more was looked at properly and is worth recording. **Nintendo
  DS** is a real candidate: its cores build for Apple platforms with no
  just-in-time compilation at all, and Mario Kart DS measured 4.1ms a
  frame mid-race against a 16.7ms budget, so speed is not the obstacle.
  The interface is: two screens and a stylus.

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
- **PS1 and Saturn multi-disc support.** Genuinely undecided rather than
  merely unbuilt, it would need real `.m3u`-style disc swapping, not just
  a missing feature flag, and nobody has weighed whether that's worth
  carrying.
- **Settings syncing across your devices via iCloud.** No confirmed real
  need yet, just an idea that comes up alongside the pairing work above.

A few ideas got explored just as seriously and reached a real answer
instead of an open question. Those live in
[docs/settled.md](docs/settled.md) rather than here: a native macOS build,
uploading a ROM from Cabinet, Atari Jaguar as a native core, and skipping
setup on a new device via iCloud.

What Cabinet doesn't do today, rather than what it might do next, is in the
[README](README.md#what-doesnt-work-yet) instead of here.
