# Cabinet for iOS 0.3.0-alpha

The biggest release Cabinet has had. Four new systems, arcade cabinets that
play with the controls they actually shipped with, and a pass over every
native core that fixed colors, sound and input lag that had been quietly
wrong since the beginning.

## Four new systems

**3DO** joins as a native core, running the Opera emulator. Your BIOS comes
from RomM the same way Saturn's always has, and in-game saves write to the
console's NVRAM and sync back to your server like everything else.

**Atari 2600** runs on Stella. One stick, one red button, and the console's
own Select and Reset switches where they belong, because on a 2600 those
switches are how you start a game and pick which variation you play.

**Vectrex** brings the vector display, and it brings the overlays with it.
Every Vectrex cartridge shipped with a translucent colored sheet that
slotted in front of the screen, and Cabinet draws them: the play field tint,
the printed control legend, the artwork around the edges. Cabinet knows
which sheet belongs to your game from the file's contents, so it works no
matter what your ROM is named. It is one switch in Settings if you would
rather see the bare vectors.

**MAME 2003-Plus** is a second arcade core alongside FinalBurn Neo, covering
the early-80s Atari and Midway boards FBNeo does not. Games that can run on
both let you pick, per game or per platform, and Cabinet remembers.

That brings Cabinet to eighteen emulator cores covering twenty-two systems,
all compiled into the app and all running natively.

## Arcade games get their real controls

The cabinets of that era were not joystick-and-buttons machines, and Cabinet
no longer pretends they were. Depending on what the board actually had, you
now get a spinner you roll with your thumb, a trackball you flick, a
steering wheel that reads how you tilt the phone, pressure-sensitive pedals,
a light gun you aim by touching the screen, and a rotary joystick where the
collar twists to aim while the stick pushes.

Tempest gets its spinner. Centipede and Missile Command get a trackball.
Pole Position gets a wheel and pedals. Light gun games reload the way they
always did, by shooting off the edge of the screen.

Which controls a cabinet gets is stated from real arcade data rather than
guessed, so a game either gets the panel it had or a standard pad, never
something invented.

## Everything looks and sounds the way it should

Emulator cores declare default settings, and Cabinet had never been
answering for them. That sounds small. It was not.

Every NES game had been rendering in a third-party color palette rather than
the NES one, with black showing as dark gray and grass as olive. Nearly the
whole picture was wrong and now it is right. NES games also draw without the
garbage rows that used to sit behind a real TV's bezel.

Arcade boards had been running their FM synthesis with no interpolation at
all, on hardware whose entire sound is FM, and in 16-bit color while Settings
said 32. Game Boy Color had no color correction, so colors meant for a dim
1998 screen were being shown raw. Neo Geo Pocket games booted in Japanese.
Saturn carried an extra frame of input lag. TurboGrafx drew three black rows
and a slightly wrong aspect ratio.

All fixed. On top of that, some deliberate upgrades: SNES Mode 7 renders at
four times the resolution in the 89 games that use it, PlayStation renders at
double resolution with 32-bit output, Genesis uses the accurate Nuked FM
chip, and NES audio runs at its highest quality setting.

## Dreamcast and Nintendo 64

Dreamcast used to run at roughly 20fps with audio breaking up, and it was
never the emulation speed. Cabinet was not applying any backpressure, so the
core free-ran at up to five times real time and threw its audio away as
static. That is fixed, along with two upstream bugs that made a second launch
crash. Dreamcast now holds 60fps in normal play with clean sound.

Nintendo 64 had been rendering at 640x480 against a documented default of
320x240 because that setting was never answered. On Apple TV that took it
from 50fps decaying to 27 up to a sustained 49.7. A crash when launching a
second N64 game after quitting the first is also fixed.

## Your saves follow you

In-game saves now work for every cartridge platform and Saturn. Cartridge
batteries, PlayStation memory cards, Sega CD backup RAM, Neo Geo Pocket
flash, the Dreamcast VMU, and 3DO NVRAM all save and upload to RomM, and
come back down on whichever device you play next.

A bug where each device quietly replayed its own cached copy of a save,
which made it look like your devices each had their own memory cards, is
fixed. Game Boy games that keep a real-time clock, like Pokemon Gold and
Silver, now keep it.

## Controllers

Twin-stick arcade games work correctly on a Bluetooth pad. Nintendo 64 uses
the button layout other emulators use on an Xbox-shaped controller, so B is
where B should be. Each platform now has its own controller personality
instead of one arcade-shaped default, and your own remappings are kept as
edits on top rather than replacing everything.

## The cartridges that had hardware inside them

A handful of Game Boy Advance games shipped with real sensors soldered into
the cartridge, and those games now work the way they were meant to, using the
phone's own motion hardware.

WarioWare Twisted is the one to try. The whole game is built around
physically twisting the cartridge, and twisting the phone now does it. Yoshi's
Universal Gravitation and Koro Koro Puzzle use their tilt sensors the same
way. Boktai's solar sensor is there too, as a setting rather than a sensor,
since pointing a phone at the sun is not something to ask of anybody.

Nothing runs until a game actually asks for it, so the gyroscope stays off for
every cartridge that never had one.

## Connection and library

Cabinet now prefers your server's local address when you are on the same
network and falls back to the public one when you are not, and the launch
screen tells you which route a game is actually about to download over.

Cover art that is not the usual box shape, which 3DO in particular has a lot
of, is now shown whole against a soft blurred backdrop of itself instead of
being cropped.

## Also fixed

The pause menu no longer offers to save a state and then complain about
something else. Launch screen pickers size themselves to their text.
Platforms RomM reports as arcade are believed, so a differently named arcade
folder is playable instead of showing as unsupported. The last game's final
frame no longer flashes at the start of the next one.

## Known rough edges

Three new cores landed the same day this was cut, and two of them got
last-minute input fixes that have not been confirmed on hardware yet.

- **Vectrex**: buttons may not respond. The cause was found and fixed, a
  pixel conversion running on the CPU that delayed touch input, but the fix
  is unverified. If a game will not start, that is why.
- **3DO**: same situation, a separate fix for the controller ports not being
  opened. Gex was the game that exposed it.
- **3DO frame rate** has been measured thoroughly on a Mac but not on device.
  It looked comfortable, but treat it as unproven. Any game can be marked as
  not working if it is not.
- **3DO saves** are verified writing and uploading to RomM. Loading a save
  back has not been confirmed end to end.

Everything else in this release has been used on real hardware. These four
are first in line for the next one.

---

This is an alpha. It is not signed, so you will need to build it yourself or
sideload it, and TestFlight is the easier path. Bug reports are very welcome.
