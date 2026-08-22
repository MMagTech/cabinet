# Cabinet for tvOS 0.2.0-alpha

The first Apple TV release that is a real app rather than a port in progress.
The previous tvOS build predates almost everything below.

## An Apple TV app, not a phone app on a television

Home is a resume banner and shelves, built for a remote and a ten-foot
viewing distance, with the Apple TV app itself as the reference. Focused
cover art lifts and its caption rides down with it. One ambient backdrop
drawn from whatever cover you are looking at colors the whole shell.

There is a real pause menu with save states, shaders, screen glow and
per-game settings, a full Library with platforms and collections, in-app
RomM account switching, and a game launch screen built for focus navigation
rather than touch.

Recently played games appear on the Apple TV's top shelf, so Cabinet's own
row on the home screen shows what you were playing.

Downloaded games live in a purgeable cache, so replaying something you played
recently skips the download entirely while still letting tvOS reclaim the
space when it genuinely needs it.

## Eighteen cores, all running natively

Every core Cabinet has on iOS runs on Apple TV: eighteen emulators covering
twenty-two systems, including this release's four new ones, 3DO, Atari 2600,
Vectrex and MAME 2003-Plus.

Vectrex brings its screen overlays with it, the translucent colored sheets
every cartridge shipped with, drawn over the vector picture the way the real
plastic sat over the real tube.

## Speed work that mattered most here

Apple TV was hit hardest by two problems that are now solved.

Dreamcast ran at roughly 20fps with breaking audio, which turned out not to
be emulation speed at all but a missing frontend brake, letting the core run
five times too fast and discard its own sound. It holds 60fps now.

Nintendo 64 was rendering at four times the pixels it should have been,
because a default resolution setting was never answered. That took Apple TV
from 50fps decaying to 27 up to a sustained 49.7.

Underneath both, the pixel decode that runs on every frame moved from the CPU
to the GPU, which alone took the general case from 30fps with 50ms stalls to
a clean 60.

## Colors, sound and input lag

The same pass that fixed iOS applies here, and it was substantial. NES games
had been drawing in a third-party palette rather than the NES one. Arcade
boards ran their FM synthesis with no interpolation and in 16-bit color.
Game Boy Color had no color correction, Neo Geo Pocket booted in Japanese,
Saturn carried an extra frame of input lag, TurboGrafx drew black rows.

All corrected, plus deliberate upgrades: four times resolution on SNES Mode 7,
double resolution and 32-bit output on PlayStation, the accurate Nuked FM chip
on Genesis, and highest quality NES audio. Each was measured on real Apple TV
hardware before shipping, including checking that the fanless box does not
throttle under them.

## Controllers and saves

Rumble works on Apple TV, which it never did before. Twin-stick arcade games
read a Bluetooth pad correctly, and Nintendo 64 uses the button layout other
emulators use on an Xbox-shaped controller.

The pause menu's B button no longer quits your game by accident, which was
the most annoying bug in the previous build.

In-game saves work for every cartridge platform and Saturn, including
PlayStation memory cards, Sega CD backup RAM, the Dreamcast VMU and 3DO
NVRAM, all syncing through RomM so you can start on Apple TV and continue on
your phone.

## Curating what plays well

Not everything runs perfectly on this hardware, so any game can be marked as
not working, from the launch screen or from a long press in the grid. Marked
games dim and carry a badge. The mark is per device on purpose, so your Apple
TV and your phone can disagree about a heavy Dreamcast game, which matches
the real difference in headroom between them.

## Under the hood

All fourteen of the tvOS core archives that existed before this release were
rebuilt after a build script bug was found that had left them sharing memory
between unrelated emulators. That was a real crash waiting to happen, and it
is fixed and verified on hardware.

---

This is an alpha. It is not signed, so you will need to build it yourself or
sideload it, and TestFlight is the easier path. Bug reports are very welcome.
