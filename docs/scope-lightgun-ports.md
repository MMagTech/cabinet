# Light guns: which cores, which ports, and what that means

Research done 2026-08-22, before any light gun work beyond arcade exists.
Nothing here is built. This is the groundwork so that whoever picks up light
guns, or the phone-as-accessory work that would drive them, does not have to
re-read eight cores' input code to learn what is already known.

Everything below was read out of the vendored core sources in `spikes/`, not
recalled. File paths are given so each claim can be rechecked.

## Eight of the eighteen cores implement light guns

Grepping for a real `RETRO_DEVICE_LIGHTGUN` implementation, excluding cores
that merely include the header:

| Core | System | Device it exposes |
|---|---|---|
| FinalBurn Neo | Arcade | light gun (`burner/libretro/retro_input.cpp`) |
| MAME 2003-Plus | Arcade | light gun, already wired in Cabinet |
| FCEUmm | NES | Zapper (`RETRO_DEVICE_ZAPPER`, a MOUSE subclass) |
| Snes9x | SNES | Super Scope, Justifier, Justifier 2P, M.A.C.S. Rifle |
| Genesis Plus GX | SMS, Genesis, Sega CD | Light Phaser, Menacer, Justifiers |
| PCSX ReARMed | PlayStation | GunCon (`RETRO_DEVICE_PSE_GUNCON`) |
| Flycast | Dreamcast | Light Gun |
| Opera | 3DO | light gun AND a separate arcade light gun |

The ten with no gun support: Beetle Saturn, Beetle PCE Fast, Beetle NGP,
Gambatte, mGBA, PicoDrive, ProSystem, Stella 2014, vecx, Mupen64Plus. (vecx
has a light PEN, which is a different device and unimplemented here.)

## The port constraint, which is the real design problem

A light gun is not simply "an input". On most of these systems it occupies a
specific controller port, and the game expects a normal pad in the other one.
Two classes:

**The gun must be player two, and player one needs a pad.**

- **SNES** (`snes9x/libretro/libretro.cpp`, the `port_1`/`port_2` tables):
  port 1 offers Joypad, Mouse and Multitap only. There is no gun option on
  port 1 at all. Super Scope, Justifier and M.A.C.S. Rifle are port 2 only,
  and the second Justifier lands on port 3.
- **Genesis / Sega CD** (`genesis_plus_gx/libretro/libretro.c` ~line 2908):
  Menacer and Justifiers appear only in the `port_2` table.
- **NES** (`fceumm/src/drivers/libretro/libretro.c` ~line 1762): the Zapper
  is offered on BOTH ports, but the game decides. Duck Hunt wants a pad on
  port 1 and the Zapper on port 2, because Start is on the pad. This is the
  case that motivated the whole question.

**The gun can be player one.**

- **Master System**: Light Phaser appears in both port tables in Genesis Plus
  GX, matching hardware where SMS gun games commonly used port 1.
- **PlayStation, Dreamcast, both arcade cores**: the gun is an ordinary
  device in the general port list with no port-1 restriction.

## Why this argues FOR the phone, rather than against it

On real hardware a solo Duck Hunt player held a gun in one hand and a
controller in the other. That is exactly the awkwardness that would make a
naive port of this feel bad.

A phone does not have that problem, because it can be both devices at once.
`LibretroFrontend` already drives ports independently (`setButtonMask:port:`,
`setPointerX:y:down:port:`, `kMaxPorts` is 2), so a phone acting as a gun can
send aim to port 2 and a Start button to port 1 in the same frame. The player
holds one object; the console sees the two devices it expects. That is better
than the original hardware rather than a compromise with it.

This is the single most useful thing in this document. Build for it from the
start rather than discovering it after shipping a gun that cannot press Start.

## Two cores configure themselves, which shrinks the work

An earlier assumption was that Cabinet would need per-game data saying "this
is a gun game", the console equivalent of `arcade-panels.json`. For two of the
platforms that is not true:

- **FCEUmm**: `retro_set_controller_port_device` with `RETRO_DEVICE_AUTO`
  reads `GameInfo->input[port]` from the core's own game database and sets
  the right device per port. The core already knows Duck Hunt needs a Zapper
  on port 2.
- **Genesis Plus GX**: "Joypad Auto" is the first entry in both port tables
  and is the default, implying equivalent detection.

So on NES and Genesis, answering AUTO may be enough. The per-game data
problem, which looked like the hardest part, largely disappears on the two
platforms where it looked worst. SNES, PlayStation and Dreamcast still need
some way to know a game wants a gun, whether that is a small data file, a
launch screen toggle, or reading what the core reports.

Note this interacts with `NativeCoreOptionsStore.padDevice(for:)`, which today
returns a single device applied to every port. A gun platform needs different
devices on different ports, which that function cannot currently express.

## The aim model question, unanswered

Cabinet's existing gun work (the arcade phone-as-gun) aims by rate control
with a crosshair the core draws, tuned over a day of real play, with an
aim-speed setting and edge-sweep offscreen reload. Arcade guns suit that.

Console light guns worked differently: they were absolute pointing devices
reading a CRT's scan position. Whether rate-control aiming feels right for
Duck Hunt, or whether those games want a genuinely absolute pointing mode,
is not something reading source code answers. It needs a build and a hand.

## What already exists to build on

- `LibretroFrontend`'s `RETRO_DEVICE_LIGHTGUN` answers, including the
  offscreen and reload ids, already generic across cores.
- `ControlLayout.Item.Kind.gun`, the touch overlay's absolute-pointing
  control kind.
- The whole phone-as-accessory transport, packet format and companion panel,
  DEBUG-gated. Its remaining shipping work (RomM presence instead of Bonjour,
  an auth handshake, a TV toggle with first-join accept) is unrelated to
  anything in this document and should be finished first.
