# In-game saves in the native player

Written 2026-08-15 after a full scrub of all fourteen native cores, when
nothing here was built yet. This exists so the findings do not have to be
rediscovered. Stage 1 of the fix landed on iOS 2026-08-16; the Status
section at the bottom records what is built and what is verified.

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

Filed as issue #5. The core by core findings came from reading the vendored
core sources in `spikes/`, not from documentation.

Stage 1 is built on iOS as of 2026-08-16: every platform whose saves ride
RETRO_MEMORY_SAVE_RAM now captures, uploads and restores through the same
memory card sync PS1 and N64 always had, Saturn included, with the Game Boy
clock travelling as its own `.rtc` file next to the card. Keeping a game
for offline also pulls the newest server save down at keep time. Two traps
were confirmed live during device testing: Saturn's freshly formatted
backup RAM reads as data (a "BackUpRam Format" text header), so it gets a
format-aware emptiness check the way PS1's directory check already worked,
and restore copies the smaller of blob and region because Genesis Plus GX
and mGBA report different sizes at restore time than at capture time.

Verified on hardware 2026-08-15/16: full save-quit-relaunch round trips on
Game Boy Advance (mGBA) and TurboGrafx-CD (Beetle PCE Fast), and the
capture-upload half on Saturn. Wired identically but not yet exercised on
a real save: SNES, NES, Game Boy, Game Boy Color, Genesis, Master System,
Game Gear, 32X, and the Game Boy clock file (no RTC-capable game in the
test library). Worst case for an unexercised platform is what it already
was, the save not surviving, so verification continues opportunistically.

Stage 2 is built on iOS as of 2026-08-16, modeled on how RetroArch never
loses these saves: cores now get a persistent per-game save directory
(CoreSaves/<rom id> under Application Support; Caches on tvOS) instead of
the per-launch temp directory, and the player shuts the core down
properly at quit, which is the one moment the file-writing cores flush
(Sega CD's bram_save, Neo Geo Pocket's flash_commit, both only inside
retro_unload_game). Restore places the file at the name the core will
look for, the loaded content's basename, before boot; capture reads it
back after the quit-time unload and syncs it through the same store as
everything else. Sega CD's backup RAM is forced per game rather than the
core's shared per-BIOS default. A side effect of the same two changes:
FBNeo's NVRAM and high scores now flush somewhere that survives, where
they previously flushed at the next launch into the prior session's
already-deleted directory.

The honest limitation, shared with RetroArch: Sega CD and Neo Geo Pocket
only flush at a clean quit, so a session ended by iOS killing the
backgrounded app loses in-game saves made since launch on those two
platforms, and on arcade.

Stage 2 device testing (2026-08-16) found and fixed two more things.
Sega CD's cart_size option must be answered: unanswered blocked Sonic
CD's boot, and "disabled" crashes the vendored core outright (an
upstream shift-overflow bug, see the forcedOptions comment), so it is
forced to RetroArch's own "4meg" default. And with a cart present,
games genuinely prefer it: Lunar put its save on the external RAM
cartridge, so the cart is synced as its own third region
("(Cabinet).cart") next to the card and the clock, verified
byte-identical between device and server.

Verified on hardware for stage 2: Sega CD capture, upload, local
restore and cart sync (Sonic CD, Final Fight CD, Lunar, Android
Assault); Neo Geo Pocket capture and upload with real flash data
(Metal Slug 1st Mission), after one earlier unexplained empty flush
that did not reproduce and is worth watching. Still owed: an NGP
relaunch check (the game's own menu finding the save again).

tvOS still syncs PS1 and N64 only; its pass follows once the feature is
finished and verified on iOS, per the finish-iOS-first rule.
