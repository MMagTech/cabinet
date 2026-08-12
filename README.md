# Cabinet

A RomM frontend for iPhone and Apple TV.

[RomM](https://github.com/rommapp/romm) manages your game collection: the
library, the metadata, the cover art, the saves. Cabinet was inspired by their
work and built to bring it to Apple devices. It puts your collection on your
iPhone and your Apple TV, opening on whatever you were playing last so you are
back in the game in one tap.

**Latest releases:**
[iOS 0.2.0-alpha](https://github.com/MMagTech/cabinet/releases/tag/v0.2.0-alpha) ·
[tvOS 0.1.0-alpha](https://github.com/MMagTech/cabinet/releases/tag/tvos-v0.1.0-alpha)

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

**A companion app for Apple TV.** The TV app runs entirely on those same
built-in cores, covering the platforms Cabinet supports natively. Your library
on the big screen with a controller in your hand.

**Your saves follow you.** Save states and battery saves sync back to your
RomM server, so they are waiting wherever you play next. PlayStation games get
their own memory card.

**Your controller just works.** Connect any controller your device supports
and play. Pair a second one for couch co-op. On iPhone there are also touch
controls, a layout per console, tuned per orientation.

## What you can play

**Natively, on both iPhone and Apple TV:** Arcade, PlayStation, Saturn,
Dreamcast, Nintendo 64, SNES, NES, Game Boy, Game Boy Color, Game Boy Advance,
Genesis, Sega CD, 32X, Master System, Game Gear, TurboGrafx-16, TurboGrafx-CD,
Neo Geo Pocket Color, Atari 7800. On iPhone these work offline once a game is
kept on your phone.

**Beyond that list, on iPhone:** whatever your RomM server plays through its
web player, with a connection. On Apple TV, the native list is the list.

## What you need

- A [RomM](https://github.com/rommapp/romm) server with your games on it
  (built and tested against 5.1.0)
- An iPhone running iOS 18 or later, or an Apple TV running tvOS 18 or later

Cabinet does not come with any games. It plays yours.

## Get it

Each platform has its own releases on its own schedule, all published under
[Releases](https://github.com/MMagTech/cabinet/releases).

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
