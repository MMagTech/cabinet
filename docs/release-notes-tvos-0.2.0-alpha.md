# Cabinet for tvOS 0.2.0-alpha

Four new systems, in-game saves that follow you between the television and
your phone, and the speed work that Apple TV needed most. Dreamcast went from
roughly 20fps to a locked 60, and Nintendo 64 from 50fps decaying to 27 up to
a steady 49.7.

## Four new systems

**3DO** runs natively through Opera, with its BIOS coming from RomM the same
way Saturn's does, and its NVRAM saves syncing back to your server.

**Atari 2600** runs on Stella, with the console's own Select and Reset
switches, because on a 2600 those are how you start a game and choose which
variation to play.

**Vectrex** brings the vector display and its overlays with it. Every Vectrex
cartridge shipped with a translucent colored sheet that slotted in front of
the screen, and Cabinet draws them over the picture the way the real plastic
sat over the real tube. It knows which sheet belongs to your game from the
file's contents, so it works whatever your ROM is named.

**MAME 2003-Plus** joins FinalBurn Neo as a second arcade core, covering the
early-80s Atari and Midway boards FBNeo does not. Games that run on both let
you pick, and Cabinet remembers your choice.

That brings Cabinet to eighteen emulator cores covering twenty-two systems,
every one of them running natively on Apple TV.

## Speed, where this hardware needed it most

Dreamcast ran at roughly 20fps with breaking audio, and it was never the
emulation speed. Cabinet applied no backpressure, so the core free-ran at up
to five times real time and threw its own audio away as static. That is
fixed, along with two upstream bugs that made a second launch crash, and the
emulated CPU is no longer underclocked eight times over by the core's own
default.

Treat Dreamcast as much improved rather than solved, and expect less of it
here than on the phone. Lighter games and the console's many 2D shooters and
fighters should play well. Heavy 3D titles are still hard: Crazy Taxi measured
60fps in normal play and 30 in its busiest streets, up from 20. This box is
also fanless and throttles itself under sustained load, which is measured and
real, so a long session can slow down where a short one did not. Its CPU speed
default is set lower than the phone's for that reason, and any game can be
marked as not working.

Nintendo 64 had been rendering at 640x480 against a documented default of
320x240, because that setting was never being answered. On Apple TV that took
it from 50fps decaying to 27 up to a sustained 49.7. A crash when launching a
second N64 game after quitting the first is also fixed.

## Colors, sound and input lag

Emulator cores declare default settings, and Cabinet had not been answering
for them. Every NES game had been drawing in a third-party color palette
instead of the NES one, with black showing as dark gray and grass as olive.
Arcade boards ran their FM synthesis with no interpolation at all, on
hardware whose entire sound is FM, and in 16-bit color while Settings said 32.
Game Boy Color had no color correction. Neo Geo Pocket booted in Japanese.
Saturn carried an extra frame of input lag. TurboGrafx drew three black rows
and a slightly wrong aspect ratio.

All corrected, plus some deliberate upgrades measured on real Apple TV
hardware before shipping: SNES Mode 7 at four times resolution in the 89
games that use it, PlayStation at double resolution with 32-bit output, the
accurate Nuked FM chip on Genesis, and NES audio at its highest quality.
Each was checked to confirm this fanless box does not throttle under them.

## In-game saves, on the television

Every platform's in-game saves now work here, not just on the phone.
Cartridge batteries, PlayStation memory cards, Sega CD backup RAM, Neo Geo
Pocket flash, the Dreamcast VMU and 3DO NVRAM all save and upload to RomM.
Start a game on Apple TV and continue it on your phone, or the reverse.

A bug where each device quietly replayed its own cached copy of a save, which
made it look like your devices each had their own memory cards, is fixed.

## Arcade games get their real controls

Where a cabinet had a spinner, trackball, wheel and pedals, light gun or
rotary joystick, Cabinet now knows it, drawn from real arcade data rather
than guessed. On Apple TV that shapes how a connected controller maps to the
board, and it is the groundwork for using your phone as the panel.

## Around the app

Recently played games now appear on the Apple TV's top shelf, so Cabinet's
row on the home screen shows what you were playing.

Any game can be marked as not working, from the launch screen or the grid,
and marked games dim and carry a badge. The mark is per device on purpose, so
your Apple TV and your phone can disagree about a heavy Dreamcast game, which
matches the real difference in headroom between them.

Focused cover art now slides its caption down with the lift instead of
burying it. A letterbox glow fills the bars beside the picture. Rumble works
on a connected controller, which it never did here before. The pause menu's B
button no longer quits your game by accident. Each Apple TV profile gets its
own second server address. Text throughout got a pass to say less and say it
the same way it is said on the phone.

## Under the hood

All fourteen tvOS core archives that existed before this release were
rebuilt. A build script bug had left them sharing memory between unrelated
emulators, including a shared Z80 between Neo Geo Pocket and Genesis, which
was a real crash waiting to happen. Fixed and verified on hardware by running
both of those systems back to back in a single session.

## Known rough edges

Three new cores landed the same day this was cut, so they have had the least
time in front of real hands.

Controls on Vectrex and 3DO were confirmed working before release, after
both needed a fix late in the day. What has not been confirmed is how
faithful the new systems feel, since nobody involved grew up with a Vectrex.
If you did, your report on whether it plays like the real thing is the most
useful thing you can send.

Two things remain genuinely unproven:

- **3DO frame rate** has been measured thoroughly on a Mac but not on a
  phone or an Apple TV. It looked comfortable, but treat it as unproven, and
  mark any game that is not as not working.
- **3DO saves** are verified writing and uploading to your server. Loading a
  save back has not been confirmed end to end, so check that a save you make
  is still there next time you play.

---

This is an alpha. It is not signed, so you will need to build it yourself or
sideload it, and TestFlight is the easier path. Bug reports are very welcome.
