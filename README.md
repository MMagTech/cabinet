# Cabinet

A RomM frontend for iPhone and Apple TV.

[RomM](https://github.com/rommapp/romm) manages your game collection: the
library, the metadata, the cover art, the saves. Cabinet was inspired by their
work and built to bring it to Apple devices. It puts your collection on your
iPhone and your Apple TV, opening on whatever you were playing last so you are
back in the game in one tap.

### [Try Cabinet on TestFlight](https://testflight.apple.com/join/caHsJFTR)
Works directly for iPhone. For Apple TV you'll also need an iPhone or iPad
to open the link on, that's an Apple TestFlight requirement, not this app.
See [Get it](#get-it) below, including the option for Apple-TV-only setups.

**Latest GitHub Releases:**
[iOS 0.4.0-alpha](https://github.com/MMagTech/cabinet/releases/tag/ios-v0.4.0-alpha) ·
[tvOS 0.3.0-alpha](https://github.com/MMagTech/cabinet/releases/tag/tvos-v0.3.0-alpha)

| | | |
|:---:|:---:|:---:|
| ![Home](docs/images/home.png) | ![Playing a game](docs/images/playing.png) | ![Library](docs/images/library.png) |

![A game in landscape](docs/images/landscape.png)

| | |
|:---:|:---:|
| ![Apple TV Home](docs/images/tv-home.png) | ![Apple TV Library](docs/images/tv-library.png) |
| ![Browsing arcade games on Apple TV](docs/images/tv-arcade.png) | ![Launching a game on Apple TV](docs/images/tv-game.png) |

## What you get

**Your RomM library on iPhone.** Cabinet plays your collection through RomM's
own web player, built right into the app.

**Offline play for supported systems.** Cabinet also ships native on-device
cores for the classic consoles and handhelds. Keep a game on your phone and it
plays with no signal and no server at all: on a plane, on the subway,
anywhere. Native speed, native controls, the whole screen.

**A real Apple TV app.** Not a phone app on a television: Home, Library and
the pause menu are built for a remote and a ten foot viewing distance, your
recent games show up on the top shelf, and it runs entirely on those same
built-in cores. Your library on the big screen with a controller in your
hand.

**Your saves follow you.** Save states and battery saves sync back to your
RomM server, so they are waiting wherever you play next. PlayStation games get
their own memory card.

**Your controller just works.** Connect any controller your device supports
and play. Pair a second one for couch co-op. On iPhone there are also touch
controls, a layout per console, tuned per orientation.

**Arcade games get the controls they actually had.** Where a cabinet used a
spinner, a trackball, a steering wheel and pedals, a light gun or a rotary
joystick, Cabinet draws that instead of pretending everything was a joystick
and two buttons. Which control a board gets comes from real arcade data
rather than guesswork.

**The small details of old hardware.** Vectrex games draw the translucent
colored overlay that shipped in the box with them. The handful of Game Boy
Advance cartridges with sensors soldered inside, WarioWare Twisted among
them, read your phone's own motion.

**Your phone is a controller for your Apple TV.** Pair it once with a code
shown on screen. Two people with two phones are two players, and phones share
seats with any controllers you already have. A friend who turns up with no
RomM server of their own can install Cabinet, skip setup entirely, and be a
controller and nothing else.

**A Nintendo DS uses both screens.** The television shows the top screen and
your phone becomes the bottom one, in your hands, as the touchscreen it always
was.

**A light gun you sight in.** Shoot the middle of the picture and two corners,
the way an arcade cabinet was set up, and the gun knows where your television
is.

**Game & Watch plays like a Game & Watch.** No on-screen controls at all. The
machine fills the screen and you press its buttons by pressing them.

**Your phone is the VMU.** While your Apple TV plays a Dreamcast game, the
controller screen on your phone shows the game's live VMU display, sitting
where the real controller's window sat. And when a game downloads a minigame
onto its memory card, Sonic Adventure's Chao Adventure being the classic,
the game's launch screen on your phone grows a VMU row: tap it and the phone
becomes the VMU, shell and all, playing the minigame off the same card your
save syncs through. Take it on the bus; your creature comes home changed.

## What you can play

**Natively, on both iPhone and Apple TV**, through twenty-three emulators built
into the app: Arcade, PlayStation, PSP, Saturn, Dreamcast, Nintendo 64,
Nintendo DS, 3DO, SNES, NES, Game Boy, Game Boy Color, Game Boy Advance,
Virtual Boy, Genesis, Sega CD, 32X, Master System, Game Gear, TurboGrafx-16,
TurboGrafx-CD, Neo Geo Pocket Color, Atari 7800, Atari 2600 and Vectrex. On
iPhone these work offline once a game is kept on your phone.

**Game & Watch, on iPhone.** The one system that is not on both: the
television has no way to touch a machine, and touching it is the whole
point. Dreamcast is the one to set expectations on, see
[what doesn't work yet](#what-doesnt-work-yet) below.

**Beyond that list, on iPhone:** whatever your RomM server plays through its
web player, with a connection. On Apple TV, the native list is the list.

## What doesn't work yet

- Amiga CD32 and Philips CD-i have no dedicated touch control layout yet,
  and both currently only play through the web player on iPhone.
- Native play only resumes from an explicit save state, not automatically
  on quit or backgrounding, unlike the web player.
- PlayStation and Saturn multi-disc games aren't supported.
- Light gun support covers the arcade cabinets. The console light gun
  systems are on the roadmap.
- Dreamcast holds 60fps with clean audio in normal play, but heavy 3D
  titles still drop frames in their busiest moments, because Apple's
  platforms don't allow the kind of just-in-time compilation that console's
  CPU needs. See [issue #6](https://github.com/MMagTech/cabinet/issues/6)
  for the full story.

## What you need

- A [RomM](https://github.com/rommapp/romm) server with your games on it
  (built and tested against 5.1.0)
- An iPhone running iOS 18 or later, or an Apple TV running tvOS 18 or later

Cabinet does not come with any games. It plays yours.

## Get it

**The easy way: [TestFlight](https://testflight.apple.com/join/caHsJFTR).**

**On iPhone:** just open that link there. It walks you through installing
TestFlight first if you don't have it, then Cabinet.

**On Apple TV, if you also have an iPhone or iPad:** install TestFlight on
that device too (signed into the same Apple ID as your Apple TV), open the
link there, and tap Accept. It installs on the Apple TV over the air, tvOS
has no browser, so the link has to be opened on the phone or iPad, not the
TV itself.

**On Apple TV only, no iPhone or iPad at all:** the public link above can't
reach you, that's an Apple limitation, not something we can work around.
Ask in [Discussions](../../discussions) or [open an issue](../../issues/new)
and I'll send you a direct email invite instead, which works from any
device, a computer included, to get a one-time code you enter on the Apple
TV.

Each platform also has its own releases on its own schedule, all published
under [Releases](https://github.com/MMagTech/cabinet/releases), if you'd
rather not go through TestFlight.

**iPhone:** download the latest iOS IPA and install it with
[AltStore](https://altstore.io) or [SideStore](https://sidestore.io).

**Apple TV:** download the latest tvOS IPA and install it with Xcode from a
Mac, or [build it yourself](docs/building.md). Friendlier install paths are
coming.

When you first open it, type in your server address and approve it in RomM.
That is all. Cabinet never asks for your password, it uses RomM's own device
authorization.

## Thanks

Cabinet exists because of the [RomM team](https://github.com/rommapp/romm).
The library, the metadata, the save model, and the web player inside the
iPhone app are all their work. Cabinet is just a way to enjoy it on Apple
devices. If you like Cabinet, go star their project, it is where the real
work lives.

## Before you install

I am not a programmer. Cabinet was built with AI assistance, by me, because I
wanted this app to exist and it did not. The entire history is here, unedited,
so you can see how it was made and judge for yourself.

## Licences

Cabinet is MIT. The emulators it uses keep their own licences, listed in
[docs/licenses.md](docs/licenses.md) and in the app under Settings.

Cabinet is free, is not sold, and takes no donations. Some of those emulators
require exactly that, so it stays that way.

Security issues: [SECURITY.md](SECURITY.md).
