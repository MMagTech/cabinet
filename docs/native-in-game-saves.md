# In-game saves in the native player

Written 2026-08-15 after a full scrub of all fourteen native cores. Nothing
here is built yet. This exists so the findings do not have to be rediscovered.

## Two different things both called saving

A **save state** is a snapshot of the whole machine, the emulator equivalent
of a bookmark. In Cabinet a save state only ever happens when someone taps
Save state in the pause menu. Nothing writes one automatically.

An **in-game save** is the game saving itself, through whatever the real
hardware had: a battery inside the cartridge, an EEPROM, a memory card, a
console's internal backup RAM. It is what happens when you save inside Zelda
or Pokémon, and it is what a player assumes is safe once the game says it
saved.

This document is about the second kind. The missing autosave for the first
kind is a separate, already known gap, listed in the roadmap.

## What works today

Three platforms capture their in-game saves, upload them to RomM, and put
them back on the next launch:

- **PlayStation**, memory card one.
- **Nintendo 64**, its combined EEPROM, SRAM, FlashRAM and Controller Pak
  blob.
- **Dreamcast**, the VMU, through a path of its own because Flycast writes a
  real file rather than handing the data over. Restoring works by writing
  that file before the core boots, using the filename Flycast falls back to
  when it cannot read the disc's own game id. If Flycast ever does read that
  id and looks for the per game name instead, the restore is ignored and the
  game starts with an empty VMU. This has not been verified on hardware.

## What does not work

Every other platform with in-game saves loses them. The game saves, play
continues, and the moment the core shuts down it is gone. There is no
warning, and because save states do work, it looks like saving in general is
fine.

| Platform | Saves in the library |
| --- | --- |
| Game Boy Advance | Nearly every game |
| SNES | Common |
| NES | Common, and the marquee RPGs |
| Game Boy and Game Boy Color | Common |
| Genesis / Mega Drive | Common, around 300 titles |
| Sega CD | Internal backup RAM |
| TurboGrafx CD / PC Engine CD | Common on CD, the 2 KB internal backup RAM |
| Saturn | Internal backup RAM, see below |
| Neo Geo Pocket / Color | Nearly every game |
| Master System | Rare, eight titles |
| Game Gear | Rare, thirty titles, mostly Japanese RPGs |
| Sega 32X | Rare, a handful |

TurboGrafx HuCards could not save at all, only the CD add-on could, so the
gap there is limited to CD games.

## Platforms with genuinely nothing to lose

- **Atari 7800.** No retail cartridge had battery backed save RAM. The High
  Score Cartridge was cancelled before release, only nine games ever
  supported it, and it stored high scores rather than progress. The core
  implements none of it.
- **Arcade.** Arcade games of this era have no save and resume concept.
  What a real cabinet keeps is its high score table and the operator
  settings behind the service menu, so the only visible loss is that those
  reset between sessions. The one exception is the Neo Geo memory card,
  which did hold real progress, but it was a separate accessory and the core
  has it switched off by default.

Note that Neo Geo Pocket is the handheld, not arcade hardware, and its saves
are the ordinary kind. The similar name is worth not tripping over.

## Why

Cabinet's core wiring exposes each core's save memory through one function,
and it is filled in for three of the fourteen cores: Mupen64Plus, PCSX
ReARMed and Flycast. Every core in the table above already offers its save
data through the standard libretro call, so this is one missing piece of
wiring repeated, not a dozen separate problems.

The player level check is the visible half of it. `hasMemoryCard`, in both
`NativePlayerView` and `TVPlayerView`, is literally PlayStation or Nintendo
64, and it gates capture, upload and restore.

## One core often covers several platforms

Cores and platforms are not the same list, and the fix has to be thought
about per platform even though the wiring is per core. Four cores cover more
than one platform each:

| Core | Platforms it runs |
| --- | --- |
| Genesis Plus GX | Genesis, Sega CD, Master System, Game Gear |
| Beetle PCE Fast | TurboGrafx-16, TurboGrafx CD |
| Gambatte | Game Boy, Game Boy Color |
| FinalBurn Neo | Arcade |

Two things follow from that.

The good half is that saves land in the right place on their own. A save is
uploaded against the game's own id in RomM, not against a platform, so RomM
files it under whichever platform that game belongs to without Cabinet having
to say. The core's name is attached too, but only so Cabinet can recognise
its own uploads rather than adopting one made by the web player. So one core
serving four platforms causes no mixing.

The awkward half is that a single core can use a different save mechanism for
each system it emulates, so wiring the core up once does not mean every
platform under it is covered. Genesis Plus GX offers cartridge save RAM for
Genesis, Master System and Game Gear through the standard call, but Sega CD's
internal backup RAM is a separate file the core writes itself, exactly the
shape Saturn is broken by below. Beetle PCE Fast maps the CD add-on's backup
RAM on both of its load paths, while HuCards have no save hardware at all, so
that core is only ever doing anything for CD games.

The practical rule: wire it per core, but confirm it per platform, and treat
Sega CD as its own case rather than assuming Genesis covers it.

## Saturn is the sharp edge

Saturn is worse than not implemented. The vendored core defaults to handing
its internal backup RAM to the frontend, which means it deliberately stops
writing its own `.bkr` file, and Cabinet never picks that data up. So Saturn
in-game saves currently have nowhere to go at all.

It is one of two small fixes: wire up the core's memory access the way the
other three cores have it, or set `beetle_saturn_save_method` to the
core's own file mode, the same way the PlayStation core already has its
memory card keys forced. Saturn's separate backup *cartridge* is a different
region again and is never exposed.

## Cores that write their own files

Neo Geo Pocket, Dreamcast and arcade do not use the shared save memory call
at all. They write real files into the save directory Cabinet hands them.
That directory is the same per launch working directory the ROM lives in,
which for a game that has not been downloaded is a temporary folder deleted
when the session ends. So those saves are likely lost too, by a completely
different route, unless the game is kept on the device. This has not been
tested, and it is the first thing to check before assuming those platforms
are fine.

Arcade has a second quirk worth knowing: FinalBurn Neo only flushes its
NVRAM when the core shuts down properly, so a session ended by iOS killing
the app loses everything since launch.

## Notes for whoever builds this

Each core reports its save memory a little differently, and most of the
surprises are about size rather than data:

- **SNES**: the pointer is never null, even for a cartridge with no battery.
  Only the size goes to zero, so the size is the thing to test.
- **Game Boy Advance**: the size is unstable early on, reporting the maximum
  until the core has worked out which save type the game uses. Ask again at
  the point of saving rather than caching it at load.
- **Genesis**: the size starts at a fixed maximum and is trimmed later, and
  save RAM that has never been written reports zero.
- **Game Boy and Game Boy Color**: the real time clock lives in a separate
  region. Saving only the save memory loses the clock, which Pokémon Gold
  and Silver depend on.
- **NES Famicom Disk System**: its save memory is the entire live disk
  image, hundreds of kilobytes rather than a few.
- **Nintendo 64**: restore after the game loads, because loading formats the
  blob.

## Status

Nothing here is built, and nothing is filed. The core by core findings came
from reading the vendored core sources in `spikes/`, not from documentation.
