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

## Decision

**mame2010.** It is simultaneously the oldest version with the metadata the
feature needs, the newest version that is practical to build, and the best
romset match for an existing 0.78 collection. Unusually, the evidence
converges instead of trading off.

Cost against 2003-plus is 18MB of binary and a per-frame time that is still
noise. The one thing to keep in mind is that this core's value for general
arcade play is a separate question from its value here; heavier boards on
0.139 were not measured.
