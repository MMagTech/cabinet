# Cabinet

An iOS app for your own [RomM](https://github.com/rommapp/romm) server.

Cabinet connects to the RomM instance you already run, shows your library, and
plays your games. It opens on whatever you were last playing, so getting back
into a game is one tap.

## What it does

**Picks up where you left off.** The home screen is your last session, not a
grid you have to navigate. One tap and you are back in the game.

**Real fullscreen.** Safari on iPhone cannot put an arbitrary element into
fullscreen, which is why RomM ships a workaround for iOS. A native app has no
browser chrome to hide, so fullscreen is simply how it looks.

**Touch controls that were designed, not generated.** Every system gets its own
layout, tuned per device size and orientation. D-pads report continuously and
their hit areas overlap, so diagonals work the way they should. Buttons have
larger touch areas than they appear to, because your thumb is not a mouse
pointer.

**Physical controllers.** Captured natively, so they work the same way they do
in any other iOS game.

**Plays offline.** Keep a game on the device and it stays playable with no
server and no signal. Saves and play history queue locally and sync back to
RomM when you reconnect.

**Saves live on your server.** Save states and battery saves go to RomM, so
they are on whatever else you play on. PlayStation games get a real memory card
per game.

## Systems

Seventeen systems run on native cores compiled into the app:

Arcade, Saturn, PlayStation, SNES, NES, Game Boy, Game Boy Color, Game Boy
Advance, Genesis, Sega CD, 32X, Master System, Game Gear, TurboGrafx-16,
TurboGrafx-CD, Neo Geo Pocket Color, Atari 7800.

Everything else your RomM server supports runs through RomM's own web player
inside the app, including N64, DS, PSP, 3DO, PC-FX, Lynx and WonderSwan. Touch
layouts and controller support work the same either way.

## What you need

- An iPhone running iOS 18 or later
- A RomM server you can reach, running RomM 4.0 or later
- Your own games on it

Cabinet ships no games and no BIOS files. It is a client for a server you
already run.

## Installing

Grab the IPA from [Releases](https://github.com/MMagTech/cabinet/releases) and
sideload it with [AltStore](https://altstore.io) or
[SideStore](https://sidestore.io).

Sideloaded apps are signed with your own Apple ID. On a free Apple ID that
signature lasts seven days, and AltStore or SideStore will refresh it for you in
the background. With a paid Apple Developer account it lasts a year.

You can also [build it from source](docs/building.md).

On first launch you enter your server address and approve the pairing in RomM's
web interface. Cabinet never asks for your password. It uses RomM's device
authorization flow, the same one built for third party clients.

## About this project

I am not a programmer. Cabinet was built with AI assistance, by me, over a
short stretch of evenings and weekends, because I wanted this app to exist and
it did not. The full commit history is here rather than squashed away, so you
can see exactly how it came together.

That is worth knowing before you decide to trust it with anything. Read the
code, or do not install it. The design reasoning is written down in
[docs/scope-v0.1.md](docs/scope-v0.1.md) if you want to see why things are the
way they are.

## Licences

Cabinet's own source is MIT. The emulator cores it links are not, and each one
keeps its own terms. Cabinet is free, is not sold, and takes no donations,
which is what keeps the non-commercial cores legitimate here.

Every core, its upstream source and its licence is listed in
[docs/licenses.md](docs/licenses.md), and in the app under Settings, Licenses.

## Security

Found something? [SECURITY.md](SECURITY.md) covers how to report it.
