# Choosing a MAME core for the unconventional-control games

Written 2026-08-21, while deciding what to build for the phone-as-controller
idea. Everything here was measured rather than recalled; the scripts are
throwaway but the numbers are not.

## The question

The games that idea targets, dials and spinners and trackballs and guns, are
mostly early-80s Atari and Midway boards. FinalBurn Neo, the arcade core
Cabinet ships today, covers the 68000-era Japanese boards instead and has
almost none of them. So the feature needs a MAME core, and MAME comes in
frozen versions that are not interchangeable.

## What decided it

Two things, and they pointed the same way.

**Per-game analog tuning metadata.** MAME declares, per game per control,
how sensitive a dial is and how far it travels (`PORT_SENSITIVITY`,
`PORT_KEYDELTA`). That is exactly what a generated phone layout needs, and
without it several hundred games would each need tuning by feel. It appears
at 0.139 and essentially does not exist below it:

    mame2000    (0.37b5)    423 drivers       0 sensitivity
    mame2003    (0.78)      717 drivers       0
    mame2003+   (0.78+)     734 drivers       3
    mame2010    (0.139)   1,057 drivers   1,548
    mame2015    (0.160)   1,932 drivers   2,073
    mame2016    (0.174)   1,999 drivers   2,103

`IPT_POSITIONAL`, the rotary-joystick control class that Heavy Barrel,
Jackal and POW use, is likewise absent below 0.139.

**Everything above 0.139 is impractical.** mame2015 does not compile on a
current Apple toolchain at all (pointer-to-INT32 casts in `src/osd/eminline.h`),
mame2016 switches to the GENie build system for almost no gain over 2015, and
current MAME means chasing upstream forever. mame2010 builds clean, needing
only the zlib `fdopen` patch this project already carries in
`tools/build-core.sh`, and it ships real `ios-arm64` and `tvos-arm64` cases in
its own Makefile.

## Performance, which turned out not to bind

Measured with `tools/lab/bench/libretro_bench` on macOS, 900 frames, mean
`retro_run` per frame in milliseconds, against a 16.7ms budget:

    game        2003-plus   2010    ratio
    cameltry      0.176     0.329   1.87x
    blstroid      0.231     0.346   1.50x
    capbowl       0.122     0.302   2.47x
    bowlrama      0.120     0.339   2.82x
    atarifb       0.083     0.136   1.63x
    arknoid2      0.127     0.454   3.59x
    720           0.248     0.573   2.31x
    apb           0.197     0.562   2.86x

mame2010 costs 1.5x to 3.6x more per frame and it does not matter: the
worst case is 0.56ms, about three percent of a frame. These are 6502-era
boards. Even several times slower on an Apple TV's A15 there is enormous
headroom, which is a different situation from the Dreamcast work where
single milliseconds were the whole fight.

Binary size, macOS dylib: mame2003-plus 30MB, mame2010 48MB. Cabinet's
FBNeo archive is already 78MB and the whole app is 129MB, so this is not a
constraint either.

## Romsets

MAME romsets are version-specific, but far less so for old boards than for
new ones, because early-80s sets were settled long before 0.78. Comparing
declared CRCs against a MAME 2003-Plus reference set of 4,859 games:

    mame2010   2,816 identical   1,197 partial   46 differ
    mame2015   2,572 identical   1,405 partial   41 differ

So a 0.78 set runs most of 0.139 unchanged, and moving to 2015 would cost
about 250 games that 2010 runs as-is. "Partial" means most files match and
some are missing: Arkanoid is one, wanting an MCU dump the older set does
not carry, which is worth knowing since it is a headline dial game.

## Decision: mame2003-plus

The first pass of this document recommended mame2010, on the strength of
its per-game analog tuning metadata. That reasoning had a hole in it: the
metadata source and the emulator do not have to be the same thing.

MAME's listxml carries `sensitivity`, `keydelta`, `minimum`, `maximum` and
`reverse` on every `<control>`, and shortnames and physical controls are
identical across versions. So the tuning data can be generated once from a
modern MAME as a data file and shipped alongside the app, exactly the way
`tools/profiles.json` already reaches `ArcadeProfiles.swift` today, while
the games run on whichever core is best to actually run them. (For the
record: mame2003-plus's own `info.c` emits only `type` and `buttons`, so
the file has to come from a newer MAME. That is a build step, not a
constraint on the core.)

Once the metadata travels separately, everything else favours 2003-plus:

- **Romsets.** A MAME 2003-Plus set runs all of its games. The same set
  gives mame2010 2,816 identical and about two thousand needing files
  topped up. For anyone whose collection is already 0.78, this is the
  single biggest practical difference.
- **Cost.** 30MB against 48MB, and 1.5x to 3.6x faster per frame. Neither
  mattered on its own, both point the same way.
- **Libretro surface.** 2003-plus exposes `xy_device`, `dialsharexy`,
  `override_ad_stick` and a built-in crosshair. mame2010 exposes a plain
  `mouse_mode` and none of the rest. These options exist for exactly this
  problem.
- **Upstream.** Committing this week, against mame2010's July.

What 2010 keeps is `IPT_POSITIONAL`, the rotary joystick class, which
2003-plus does not have. That turns out not to matter: it represents Ikari
Warriors, Heavy Barrel and Jackal as `IPT_DIAL`, so those games are
playable and arrive as a mechanism a phone already implements well.

One assumption to verify rather than trust: sensitivity values measured
against a modern MAME's analog implementation, applied to a 0.78 core's,
may not mean precisely the same thing. Cheap to check on a couple of games
once the pipeline exists.

The performance and size numbers above stand as measured; only the
conclusion drawn from them changed.
