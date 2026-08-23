# Licences

Cabinet's own source is MIT. The emulator cores it links are not, and each keeps
its own terms. This page lists everything the app binary contains, where it came
from, and the exact commit it was built from.

The same list, with every licence readable in full, is in the app under
Settings, Licenses.

## Why the distinction matters

Several of these cores are free for non-commercial use but may not be sold.
Cabinet is free, is not sold, and takes no donations, which is what keeps those
cores legitimate in this build. That is a deliberate constraint on the project,
not an oversight: adding a sponsor button or charging for the app would break
it.

Cabinet ships no games and no BIOS files.

## Cabinet

| | |
|---|---|
| Licence | MIT |
| Source | This repository |

Covers everything under `RommApp/` except the prebuilt `lib*.a` files listed
below and the third party C sources in `RommApp/RommApp/Native/Archive`.

## Emulator cores

Each of these is a prebuilt static library in `RommApp/RommApp/Native/<name>/`.
None of them were modified. They were built from upstream with
`tools/build-core.sh`, which is in this repository, so anyone can reproduce them
from the commits below.

| Core | Systems | Licence | Upstream | Commit |
|---|---|---|---|---|
| FinalBurn Neo | Arcade | Free for non-commercial use, plus MAME's terms | [libretro/FBNeo](https://github.com/libretro/FBNeo) | `2444fbe3ddab` |
| MAME 2003-Plus | Arcade | MAME 0.78 non-commercial license | [libretro/mame2003-plus-libretro](https://github.com/libretro/mame2003-plus-libretro) | `93159c0ce9f8` |
| Beetle Saturn | Saturn | GPL v2 | [libretro/beetle-saturn-libretro](https://github.com/libretro/beetle-saturn-libretro) | `84461434f249` |
| PCSX ReARMed | PlayStation | GPL v2 | [libretro/pcsx_rearmed](https://github.com/libretro/pcsx_rearmed) | `da2cb8ecd17f` |
| Flycast | Dreamcast | GPL v2 | [flyinghead/flycast](https://github.com/flyinghead/flycast) | `a172e0001351` |
| mupen64plus-libretro-nx (bundles GLideN64) | Nintendo 64 | GPL v2 | [libretro/mupen64plus-libretro-nx](https://github.com/libretro/mupen64plus-libretro-nx) | `f275caf4b2bf` |
| Snes9x | SNES | Free for non-commercial use | [libretro/snes9x](https://github.com/libretro/snes9x) | `ed750a49d058` |
| FCEUmm | NES | GPL v2 | [libretro/libretro-fceumm](https://github.com/libretro/libretro-fceumm) | `b5e3566515c2` |
| Gambatte | Game Boy, Game Boy Color | GPL v2 | [libretro/gambatte-libretro](https://github.com/libretro/gambatte-libretro) | `96174369b3c3` |
| mGBA | Game Boy Advance | MPL 2.0 | [libretro/mgba](https://github.com/libretro/mgba) | `e31759b24e7a` |
| Genesis Plus GX | Genesis, Sega CD, Master System, Game Gear | Free for non-commercial use | [libretro/Genesis-Plus-GX](https://github.com/libretro/Genesis-Plus-GX) | `84fcf2ec8e6b` |
| PicoDrive | 32X | Free for non-commercial use | [libretro/picodrive](https://github.com/libretro/picodrive) | `6248b51ffbe2` |
| Beetle PCE Fast | TurboGrafx-16, TurboGrafx-CD | GPL v2 | [libretro/beetle-pce-fast-libretro](https://github.com/libretro/beetle-pce-fast-libretro) | `b211204c7026` |
| Beetle NeoPop | Neo Geo Pocket Color | GPL v2 | [libretro/beetle-ngp-libretro](https://github.com/libretro/beetle-ngp-libretro) | `a50d5ac288a8` |
| Beetle VB | Virtual Boy | GPL v2 | [libretro/beetle-vb-libretro](https://github.com/libretro/beetle-vb-libretro) | `3f53a40bf8aa` |
| melonDS | Nintendo DS | GPL v3 | [libretro/melonDS](https://github.com/libretro/melonDS) | `66b5d2634cd0` |
| DraStic FreeBIOS | DS BIOS replacement inside melonDS | BSD 2-clause | bundled in the fork above | `66b5d2634cd0` |
| ProSystem | Atari 7800 | GPL v2 | [libretro/prosystem-libretro](https://github.com/libretro/prosystem-libretro) | `363b6dfbd3e2` |
| vecx | Vectrex | GPL v3 | [libretro/libretro-vecx](https://github.com/libretro/libretro-vecx) | `8f671cc9d737` |
| Stella 2014 | Atari 2600 | GPL v2 | [libretro/stella2014-libretro](https://github.com/libretro/stella2014-libretro) | `4a7da82595d2` |
| Opera | 3DO | Modified LGPL, non-commercial (FreeDO terms) | [libretro/opera-libretro](https://github.com/libretro/opera-libretro) | `a501a278d057` |

The GPL v2 cores are statically linked, which makes the distributed app a
combined work under those terms. The corresponding source is the upstream commit
named above, unmodified, built with `tools/build-core.sh` from this repository.

## Supporting libraries

| Library | Used for | Licence |
|---|---|---|
| libretro-common | The core interface the cores are built against | MIT |
| zlib | ROM decompression | zlib licence |
| libchdr | Reading CHD compressed disc images | BSD |
| Zstandard | Disc image decompression | BSD |
| LZMA SDK | Archive decompression | Public domain |
| Tremor | CD audio decoding | BSD |
| inih | Config parsing, built into mGBA | BSD |

## Bundled artwork

The Vectrex screen overlay images in `Resources/VectrexOverlays` are vector
recreations of the translucent sheets that shipped with every Vectrex
cartridge, taken from
[libretro/overlay-borders](https://github.com/libretro/overlay-borders)
(MIT-licensed repository; credits THK and Gigapig of the Hyperspin
community). The underlying overlay designs are 1982 to 1984 GCE artwork;
they are reproduced here the same way the wider emulation community has
distributed them for years, non-commercially and for preservation. Anyone
with a claim to the originals is welcome to open an issue.

## Not bundled

RomM's own web player runs the emulators it ships, including MAME 2003, FB Alpha
and the rest, inside a page served by your server. Cabinet does not bundle those
and they are RomM's attribution to make, not Cabinet's.
