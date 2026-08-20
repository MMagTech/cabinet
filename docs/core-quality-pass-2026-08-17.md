# Native core quality pass, 2026-08-17

An autonomous first pass over the natively compiled cores that already hold
full speed, looking for quality and accuracy that conservative or simply
unapplied settings were leaving on the table.

**Nintendo 64 and Dreamcast are excluded.** Both are separate in-flight
investigations. Nothing here changes their options, their defaults, their
integration, or any shared code in a way that reaches them, and the two
places that could have (`NativeCoreOptionsStore.dictionary(for:)` and the
new `restoredDefaults(for:)`) name them explicitly rather than relying on
them happening to fall through.

## The finding that shaped the pass

`LibretroFrontend` answers neither `RETRO_ENVIRONMENT_SET_VARIABLES` nor
`SET_CORE_OPTIONS_V2`, and `NativeCoreOptionsStore.dictionary(for:)` only
sent keys somebody had changed in Settings. A core asked for a key nobody
answers does not fall back to the value its own option table declares; it
falls back to whatever its C global was initialised to. Those are not the
same value, and RetroArch never sees the difference because registering the
options is exactly what seeds its answers.

This is the same gap-class already recorded for N64 (zeroed globals) and
Sega CD (`cart_size`), but it had never been checked across the other
cores. It turns out to have been costing real picture and audio quality on
five platforms.

## How it was measured

Two harnesses, both new, both committed.

`tools/bench/libretro_bench.c` runs any core headless on macOS and answers
**exactly** what `LibretroFrontend` answers, silences included. That is the
whole point: a harness that answered `SET_CORE_OPTIONS_V2` would measure a
core Cabinet never runs. It reports per-frame `retro_run` time, audio frames
produced against the declared rate, geometry, and a hash of the video and
audio output so "did this actually change anything" is a comparison, not an
opinion. It takes scripted input (`-i frame,button,hold`) so a run can walk
itself into a game's attract demo instead of benchmarking a title screen,
and dumps PPM frames for visual comparison.

`RommApp/RommApp/Native/NativeBenchHarness.swift` plus
`tools/bench/device_bench.sh` do the same job on the iPhone: launch straight
into a kept game, run for N seconds, flush `FrameTrace`, exit. It is
`#if DEBUG && os(iOS)` and gated on a launch argument nothing else passes.
`-cabinetBenchStockOptions 1` reverts the option changes at runtime, so one
build measures both sides of an A/B.

Test devices: iPhone Air, and an Apple TV 4K 3rd gen once the Dreamcast
session released it. **Both platforms are measured**; nothing here rests on
extrapolating from one to the other, which turned out to matter.


## Measured on device, iPhone Air

One kept game per core, 40 seconds each, launched headless. Both columns
come from the same build; the "stock" side runs with
`-cabinetBenchStockOptions 1`, which reverts this pass's option changes at
runtime.

**Read the p99 column, not the median.** Device runs are not
content-deterministic: the harness starts a game and lets it sit, so two
runs of the same game can spend their 40 seconds on different screens. That
is exactly what produced an alarming-looking "mGBA 2.34x regression" below,
where the median doubled while p99 moved 18.7% to 18.5%: nothing regressed,
one run simply sat on a busier screen. p99 is the stable statistic across
runs, and the deterministic A/B ratios all come from the macOS bench
instead.

```
system                     geometry          core ms   budget med   budget p99   audio
beetleNGP                   160x152  1.916-> 1.921 1.00x  12.6-> 12.5%  16.3-> 16.3%  1.005
beetlePCEFast          256x243->256x240  1.237-> 1.234 1.00x   9.1->  9.0%  11.5-> 11.3%  1.000
beetleSaturn                704x240  7.304-> 6.172 0.85x  44.3-> 37.5%  64.6-> 46.2%  1.000
fbneo                       320x240  5.347-> 5.165 0.97x  33.1-> 31.8%  89.3-> 88.9%  1.000
fceumm                 256x240->256x224  1.346-> 1.334 0.99x   9.1->  9.0%  12.1-> 11.1%  1.000
gambatte_gbc                160x144  0.570-> 0.567 0.99x   4.4->  4.4%   6.5->  6.1%  1.000
genesisPlusGX_cd            256x224  2.082-> 2.082 1.00x  14.2-> 14.2%  20.3-> 22.3%  1.000
genesisPlusGX_gg            160x144  0.449-> 0.451 1.00x   4.1->  4.1%   8.2->  8.3%  1.000
mgba                        240x160  0.699-> 1.638 2.34x   5.5-> 11.0%  18.7-> 18.5%  1.000
pcsxReARMed                 512x240  5.804-> 5.816 1.00x  37.0-> 37.0%  56.0-> 46.0%  1.000
picoDrive                   320x224  4.280-> 4.282 1.00x  26.7-> 26.7%  37.1-> 36.7%  1.000
prosystem                   320x223  0.757-> 0.760 1.00x   6.0->  6.0%   8.4->  8.8%  1.000
snes9x                      256x224  1.738-> 1.729 0.99x  12.6-> 12.5%  16.1-> 16.3%  1.000
```

Two geometry corrections show up directly: NES 256x240 to 256x224 and
TurboGrafx 256x243 to 256x240. Every core kept an audio ratio of 1.000 and
a nominal thermal state, and no change cost measurable core time.

**The headroom picture is not uniform.** Arcade is by far the tightest:
FBNeo on Deathsmiles is bimodal, a 31.8% median with an 89% p99, so a CAVE
board in a heavy scene has about a tenth of a frame to spare. Saturn (46%),
PS1 (46%) and 32X (37%) sit in the middle. Everything else is under 20% and
has room to burn.

## Two traps worth recording

**A failed device run looks exactly like a clean no-change result.** The
trace file persists on the device between runs, so if a launch fails and the
script copies anyway, it hands back the *previous* run's numbers. This
happened for real: the iPhone auto-locked partway through a batch, every
later launch failed with "the device was not, or could not be, unlocked",
and twelve runs produced byte-identical before/after numbers that read
perfectly as "this option does nothing". `device_bench.sh` and `wave2.sh`
now check the launch log for a clean exit and refuse to copy otherwise.

**Naming an output file after the core, not the test, silently eats
results.** Three rows of the sweep share Genesis Plus GX and two share
Gambatte, so the later row's copy overwrote the earlier row's file before it
was renamed. Fixed by threading the label through.

## Per system

### NES, FCEUmm

**Baseline** No options sent at all. **Headroom** core 1.31ms median of a
16.64ms budget, 8.9% used, audio ratio 1.000, thermal nominal.

| | |
|---|---|
| Kept | `fceumm_palette=default` |
| Why | `current_palette` is a static `0` (libretro.c:327), and 0 is `palettes[0]`, the third-party "asqrealc" set, not the core's own NES palette (the separate `PAL_DEFAULT` sentinel at libretro.c:458). 98.3% of pixels in a Contra frame differed. Black sat at (16,16,16) instead of (0,0,0); grass rendered olive (88,100,0) instead of green (0,150,0). Every NES game this app has run has used a washed-out third-party palette. |
| Confidence | **Objectively verified.** |

| | |
|---|---|
| Kept | `fceumm_overscan_v_top=8`, `v_bottom=8`, `h_left/right=0` |
| Why | The NES draws 240 lines but the top and bottom 8 sat behind the bezel, which is why the core's own default crops them and why RetroArch, Nestopia and Mesen all ship cropped. Unanswered, both stayed 0 and the full 256x240 buffer including those rows was aspect-fitted as if they were content. Checked before keeping: in the Contra frame all 16 rows are a single flat colour, so nothing with detail in it is lost. |
| Confidence | **Needs your eye.** This is the one change that visibly removes picture. It is one line to revert. |

| | |
|---|---|
| Kept | `fceumm_sndvolume=7` |
| Why | The core inits `sndvolume` to 150 of 256 (libretro.c:4038) but documents 7-of-7 as the default, which its own arithmetic turns into 179. A 19% level increase, not a tone change. |
| Confidence | Objectively verified that the value was not the declared default. |

| | |
|---|---|
| Candidate | `fceumm_sndquality=Very High` |
| Cost | 1.27x core time (0.43 to 0.55ms on the bench). |
| Status | Pending headroom confirmation, see below. |

### TurboGrafx-16 and TurboGrafx-CD, Beetle PCE Fast

| | |
|---|---|
| Kept | `pce_fast_initial_scanline=3`, `pce_fast_last_scanline=242` |
| Why | Unanswered, the core renders scanlines 0 through 242 and hands over a 256x243 frame whose first three rows are always black. Rows 3...242 of the current output are byte-identical to the whole of the corrected 240-row output, so the only things those rows contribute are a black band at the top and a 1.25% vertical stretch error in the aspect fit. 3 and 242 are the core's own documented defaults. |
| Confidence | **Objectively verified.** Nothing is lost; three black rows go away. |

### Neo Geo Pocket Color, Beetle NGP

| | |
|---|---|
| Kept | `ngp_language=english` |
| Why | `setting_ngp_language` is a static 0, which is Japanese; the core documents english. Changed both video and audio output on SNK vs Capcom, which is a bilingual cart that had been booting in the wrong language. |
| Confidence | **Objectively verified.** |

### Game Boy and Game Boy Color, Gambatte

| | |
|---|---|
| Kept | `gambatte_gbc_color_correction=GBC only` |
| Why | A Game Boy Color's screen was far darker and less saturated than a modern display, and Gambatte ships a correction defaulted on for CGB titles. Its `colorCorrection` global is a static 0 (libretro.cpp:2320) and the key was never answered, so every GBC game rendered raw, oversaturated values. Inert on true mono roms. |
| Confidence | High. The mechanism is verified in source and the output changes; whether the corrected look is preferable is a look. |

| | |
|---|---|
| Kept | `gambatte_gb_colorization` now always sent at its resolved value |
| Why | Cabinet's Settings screen showed "Colorization: Off" while the core was in a different state entirely: unanswered, Gambatte returns early before applying any palette, and mono games rendered with a slight green cast, (80,84,80) and (248,252,248). Answered "disabled" it applies a true neutral greyscale. Small, but it makes the setting describe the machine, and Cabinet already has a Game Boy shader that owns the authentic green look; stacking a hidden tint underneath it double-applied the effect. |
| Confidence | Objectively verified that the state did not match the UI. The visual delta is minor. |

### Arcade, FBNeo

| | |
|---|---|
| Kept | `fbneo-allow-depth-32` now always sent at its resolved value (`enabled`) |
| Why | `bool bAllowDepth32 = false;` (retro_common.cpp:55), and libretro.cpp:1746 forces `nBurnBpp = 2` whenever it is false. Cabinet's own Settings screen has shown "32-bit color: Enabled" since the option was added, with a comment saying `enabled` is FBNeo's default, while every arcade game actually rendered 16-bit because the key was only sent if somebody toggled it. |
| Confidence | The state mismatch is certain from source. The **picture** impact is much narrower than first written; see below. |

| | |
|---|---|
| Kept | `fbneo-sample-interpolation` and `fbneo-fm-interpolation` at `4-point 3rd order` |
| Why | Both are declared "4-point 3rd order" in FBNeo's own table and neither ever reached it: `INT32 nInterpolation = 1` and `INT32 nFMInterpolation = 0` (burn.cpp:79-80). So sample playback ran at 2-point and FM synthesis at no interpolation at all. |
| Confidence | Verified from source that neither was at its declared default, and verified on the macOS bench that it genuinely changes the audio, which the colour-depth change below notably does not. Audio hashes over 1800 frames: **Neo Geo (shocktr2) differs, Capcom (1943u) differs, CAVE CV1000 (deathsml) identical.** CV1000 drives a YMZ770 streaming sound chip rather than the YM2610/YM2151 FM path these options feed. "Differs" is not "sounds better", which needs ears, but higher-order interpolation means less resampling aliasing and this is the core's own declared default. |

`fbneo-samplerate` has the same shape of mismatch (declared 48000,
unanswered 44100) and was **left alone**: FBNeo's own source carries a
comment that Neo Geo CD CDDA playback has issues at anything but 44100, and
this frontend fixes its audio format when playback starts. That comment was
taken on trust and never tested; the bench can now settle it.

**Taken together with the colour-depth result below, the honest summary for
arcade is that on Deathsmiles, the most-played game in this library, neither
arcade change does anything at all.** Both are real on Neo Geo and Capcom
boards.

**How much this actually improves: measured, and the answer is nothing
visible.** The first draft of this document claimed banding and gradient
improvements from reasoning about palette bit depths. That reasoning was
never checked against pixels, and when it finally was, it did not survive.

FBNeo was built for the macOS bench (`spikes/cores/fbneo-macos`) and the
same frames were captured at both depths, with the pixel format confirmed
to actually differ each time (RGB565 against XRGB8888, verified through the
harness's `BENCH_TRACE_VARS` tracing rather than assumed):

| Game | Board | Format flips? | Pixels differing, 3 frames each |
|---|---|---|---|
| deathsml | CAVE CV1000 | yes, 2 to 1 | **0** |
| shocktr2 | Neo Geo | yes, 2 to 1 | **0** |
| batrider | Toaplan/Raizing | yes, 2 to 1 | **0** |
| 1943u | Capcom pre-CPS | yes, 2 to 1 | **0** |
| guwange | CAVE 68k | **no**, `BDF_16BIT_ONLY` | n/a, option cannot apply |

Twelve comparisons, every one byte-identical. The mechanism explains it:
`HighCol16` truncates to 5-6-5, and a board whose palette holds five bits
per channel round-trips through that losslessly. CAVE (`cave_palette.cpp:30`)
and Toaplan (`toa_palette.cpp:26`) are RGB555. Neo Geo does build six bits
per channel from four plus a shared dark bit (`neo_palette.cpp:70`), so it
*can* differ in principle, but these games evidently do not exercise the
dark bits in the frames sampled. And 3,080 of FBNeo's 25,373 drivers carry
`BDF_16BIT_ONLY`, which forces 16-bit no matter what the option says;
Guwange is one of them.

**So why keep it?** Not for colour. Three reasons that survive:

1. It costs nothing, and slightly less than nothing: Cabinet's RGB565 GPU
   unpack pass disappears in favour of a direct 32-bit upload, measured at
   0.164ms to 0.128ms across two independent device run pairs, a 22% fall
   despite the frame carrying twice the bytes. Core time is unchanged.
2. It makes the Settings screen describe the machine. It has read "32-bit
   color: Enabled" since the option was added while the core ran 16-bit.
3. FBNeo's own option text is "some games require this to render properly".
   None of the five tested here do, but that is five of 141 in this library.

That is a fair trade, but it is a correctness-and-honesty change, not a
picture improvement, and it should not be described as one.

### PlayStation, PCSX ReARMed

**Baseline** Only the two memory-card keys. **Workload** Crash Bandicoot 2's
own attract demo, which is real 3D and replays deterministically.

| | |
|---|---|
| Kept | `pcsx_rearmed_spu_interpolation=gaussian` |
| Why | The PlayStation SPU interpolates sample playback with a fixed 4-point Gaussian kernel. "simple" is pcsx_rearmed's cheap approximation, defaulted for handhelds that could not afford the real thing. 0.98x the core time of "simple", inside run-to-run noise. |
| Confidence | **Objectively verified** as free; the accuracy claim is the hardware's documented behaviour. |

| | |
|---|---|
| Candidate | `pcsx_rearmed_neon_enhancement_enable` (2x internal resolution, 512x240 to 1024x480) |
| Cost | 1.68x core time on the attract demo. |
| Status | Pending device headroom. |

| | |
|---|---|
| Candidate | `pcsx_rearmed_rgb32_output` |
| Cost | 1.15x core time, but it also moves Cabinet's renderer off the RGB565 GPU unpack pass onto a straight 32-bit upload, so the net is not the core number alone. |
| Status | Pending device measurement. |

### SNES, Snes9x

Core is clean: every documented default already matches its compiled-in
state, verified by running the full default set and getting a byte-identical
frame and audio hash.

| | |
|---|---|
| Candidate | `snes9x_mode7_hires=4x_hv` (Mode 7 planes at 1024x448) |
| Cost | 1.02x core time. Crucially the core only emits the large frame for the 11% of frames that actually use Mode 7; the other 88% stay 256x224. The real cost is Cabinet's texture upload during those scenes, and a texture reallocation at each transition. |
| Status | Pending device measurement. |

### Genesis, Sega CD, Master System, Game Gear, Genesis Plus GX

Core is clean: `config_default()` seeds everything, and the full documented
default set produced a byte-identical result.

| | |
|---|---|
| Candidate | `genesis_plus_gx_ym2612=nuked (ym2612)` |
| Cost | 2.33x core time (0.345 to 0.805ms on the bench). |
| Why | Nuked OPN2 is the die-accurate YM2612 reimplementation; MAME's is the fast approximation. The textbook "accuracy option disabled for performance". |
| Status | Pending device headroom. |

### Sega 32X, PicoDrive

Clean, and no free win. Documented defaults already match the compiled-in
state, and `picodrive_renderer=accurate` and `sound_rate=44100` were already
in effect. This is the heaviest non-PS1 core measured (1.42ms/frame on Doom
32X on the bench). Investigated and closed.

### Sega Saturn, Beetle Saturn

| | |
|---|---|
| Kept | `beetle_saturn_midsync=enabled` |
| Why | `bool setting_midsync;` is an uninitialised global (libretro_settings.c:17), so false, while the core declares it enabled. It feeds `AllowMidSync` (mednafen/ss/ss.c:1502), the flag that lets the emulator break out mid-frame to re-read input rather than sampling once per frame. Worth roughly a frame of input latency. Measured 1.01x core time with byte-identical video and audio, on the heaviest core in the app. |
| Confidence | Objectively verified as near-free and as not the declared default. The latency improvement itself is a real-hardware property of the flag, not something this harness can time. |

**Found and deliberately not changed:** Beetle Saturn has the same
unanswered scanline pair PCE does (`initial_scanline=8`,
`last_scanline=231`, which would take Die Hard Arcade from 704x240 to
704x224). But the rows it would remove are not PCE's: PCE's three are pure
black in every frame checked, while Saturn's bottom eight carry real drawn
pixels, 146 to 154 distinct colours per row. Cropping them is a judgement
about what a CRT would have hidden, not a correction, so it is your call.

### Game Boy Advance, mGBA. Atari 7800, ProSystem

Both clean. Every documented default already matches the compiled-in state.
No opportunity found worth the risk. Investigated and closed.

## Not pursued, and why

- **Blargg NTSC filters, CRT/LCD looks, interframe blending, low-pass audio
  filters, widescreen and no-sprite-limit hacks, overscan expansion.** All
  subjective, all off upstream. Cabinet already offers the look-based ones
  as shaders, which is the right place for them.
- **`genesis_plus_gx_render=double field`.** Measured, changed nothing on a
  progressive game, and Genesis titles that use interlace are rare.
- **`snes9x_overclock_cycles`, `fbneo-cpu-speed-adjust`,
  `genesis_plus_gx_no_sprite_limit`.** These change what the hardware did,
  not how accurately it is reproduced.

## Apple TV, measured

The Apple TV 4K 3rd gen is an A15 rather than an A19 and has no fan, so
every change was re-measured there rather than assumed. Same harness, same
40-second runs, `tools/bench/sweep_tv.sh`.

```
system                     geometry          core ms   budget med   budget p99   audio
beetleNGP                   160x152  3.465-> 3.440 0.99x  22.4-> 22.3%  27.3-> 27.1%  1.005
beetlePCEFast          256x243->256x240  2.289-> 2.285 1.00x  16.4-> 16.2%  19.3-> 18.7%  1.000
beetleSaturn                704x240  6.691-> 6.704 1.00x  40.9-> 40.9%  56.4-> 54.9%  1.000
fbneo                       320x240  6.008-> 6.085 1.01x  37.4-> 37.7%  86.2-> 87.7%  1.000
fceumm                 256x240->256x224  2.287-> 3.914 1.71x  15.7-> 25.1%  18.0-> 27.5%  1.000
gambatte                    160x144  0.753-> 0.754 1.00x   6.4->  6.4%   8.6->  8.6%  1.000
genesisPlusGX               320x224  3.192-> 3.196 1.00x  22.0-> 22.0%  25.6-> 25.9%  1.000
mgba                        240x160  1.134-> 1.124 0.99x   9.3->  9.1%  29.9-> 30.1%  1.000
pcsxReARMed                 512x240  6.234-> 6.322 1.01x  39.4-> 40.4%  50.5-> 49.2%  1.000
picoDrive                   320x224  5.748-> 5.743 1.00x  36.0-> 36.1%  43.9-> 44.6%  1.000
prosystem                   320x223  1.263-> 1.258 1.00x   9.9->  9.9%  12.6-> 12.4%  1.000
snes9x                      256x224  3.171-> 3.169 1.00x  22.3-> 22.3%  28.5-> 28.4%  1.000
snes9x_fzero           256x224->1024x448  4.719-> 5.193 1.10x  31.5-> 36.2%  34.4-> 45.6%  1.000
```

Both geometry corrections show up here too, and nothing costs more than
noise. Mode 7 is the widest platform gap, 45.6% at p99 against the iPhone's
33.1%, which is what a slower fanless box should look like; it keeps 54% of
the frame free.

**Two changes were iOS-only on an estimate and are not any more, because the
estimate was wrong in the safe direction.** Genesis Nuked OPN2 measured
43.1% and 42.5% at p99 across two titles against a 25.9% baseline, not the
55% to 75% predicted. PS1 2x plus 32-bit output measured 51.3% to 58.8%, a
7.5 point cost against the iPhone's own 14.5. Both now ship on both
platforms, so the two products stay in step.

**On the thermal worry specifically**, which was the reason for gating: the
261-second PS1 trace shows no drift across its own duration, core time at
6.255ms median in the first window and 6.271ms in the last, thermal nominal
throughout. The duty-cycling the Dreamcast investigation measured on this
box needs a workload pinning the SH4 interpreter near 100%. Nothing in this
pass gets it warm enough. That is a statement about these workloads, not a
claim that the box does not throttle.

**Arcade is the one number to keep an eye on**: 87.7% of budget at p99 on
Deathsmiles, essentially the same cliff the iPhone shows at 88.2%. This pass
does not move it (the 1.5 point difference is inside the roughly 15% floor
below which an un-cooled Apple TV cannot resolve anything), but it is the
first thing to look at if an arcade game ever stutters there.

## Status of each change

Every change below is device-verified on an iPhone Air with a clean launch,
an audio ratio of 1.000 and a nominal thermal state. Costs are quoted as p99
of frame budget, because device runs are not content-deterministic and p99
is the statistic that holds still across runs.

| Change | Budget p99 before | after | Verdict |
|---|---|---|---|
| NES palette, overscan, volume | 12.1% | 11.1% | Free |
| NES `sndquality=Very High` | 11.1% | 16.3% | Kept, 84% margin |
| TurboGrafx scanlines | 11.5% | 11.3% | Free |
| NGPC language | 16.3% | 16.3% | Free |
| GBC colour correction | 6.5% | 6.1% | Free |
| Saturn midsync | 64.6% | 46.2% | Free |
| PS1 Gaussian SPU | 56.0% | 46.0% | Free |
| Arcade 32-bit + FM interpolation | 88.9% | 88.2% | Kept, no cost at the peak |
| Genesis `ym2612=nuked` | 15.9% | 37.4% | Kept, 63% margin |
| PS1 2x internal resolution + 32-bit output (iOS only) | 53.3% | 67.8% | Kept, 32% margin |
| SNES Mode 7 at 4x_hv | 20.4% | 33.1% | Kept, 67% margin |

Two of these deserve a note.

**Arcade was the one at risk and it came through clean.** FBNeo on
Deathsmiles is the tightest core in the app, bimodal with a 32% median and
an 89% p99, so a CAVE board in a heavy scene has about a tenth of a frame
spare. Turning on 32-bit colour depth and 4-point interpolation on both
sample and FM playback moved the worst-case frame from 88.9% to 88.2%,
which is to say not at all. The interpolation cost is per audio sample, a
few hundred thousand operations a second against a core spending five
milliseconds a frame, and the 89% is CV1000 CPU emulation rather than
anything to do with sound.

**Genesis Nuked OPN2 is the one real spend in this pass**, 2.25x to 2.44x
the core's time depending on title, and it is worth it: it is the die-accurate YM2612 against MAME's fast
approximation, and it still leaves 63% of the frame budget free. Video output was byte-identical in every bench run, which matters because
Genesis games poll the YM2612 status register for timing, so a different
chip model could have changed game behaviour and demonstrably does not.

Sampled across three titles rather than one, after the first draft rested
entirely on Gunstar Heroes: p99 of frame budget 37.4% (Gunstar Heroes),
37.2% (Thunder Force III, measured directly against MAME's 16.7%) and 36.4%
(Streets of Rage 2). Consistent to within a point, audio at exactly
realtime on all three.

## Left as recommendations, not enabled

**SNES Mode 7 internal resolution: taken, and the ladder was measured on
device.** `snes9x_mode7_hires=4x_hv` renders Mode 7 planes at 1024x448
instead of 256x224. F-Zero, which is Mode 7 for essentially its whole
running time, in the same 45-second window each way, p95 of frame budget
over the Mode 7 frames only:

| Setting | Buffer | core ms | upload ms | p95 of budget |
|---|---|---|---|---|
| disabled | 256x224 | 2.716 | 0.336 | 20.4% |
| 2x | 512x224 | 3.215 | 0.370 | 26.3% |
| 2x_hv | 512x448 | 3.365 | 0.532 | 27.8% |
| 4x | 1024x224 | 4.075 | 0.347 | 34.0% |
| **4x_hv** | **1024x448** | **4.242** | **0.569** | **33.1%** |

The ladder settles the choice cleanly: 4x_hv costs the same as 4x while
doubling vertical resolution as well, because the expense is horizontal
Mode 7 sampling rather than the size of the buffer. So the top of the
ladder is also the best value on it, and there is no reason to back down to
2x. p99 is 37.7%, audio holds 32,032 frames a second against 32,040
declared, thermal nominal.

**A number in an earlier draft of this document was wrong and is worth
recording as a lesson.** The macOS bench reported this option at 1.02x core
time and the whole ladder as flat within noise. That measurement was
worthless: F-Zero sat in menus for the entire bench window, so it timed
Mode 7 being switched on while Mode 7 was never drawn. The real cost is
1.56x. A feature that only costs something while it is active has to be
measured with it active, and the harness will report a confident, stable,
repeatable number for a window in which nothing happened. The same mistake
produced a first round of arcade colour-depth results taken from boot
screens with three distinct colours in them.

**PS1 32-bit output: taken.** `pcsx_rearmed_rgb32_output` costs 1.15x core
time on the bench and measured cost-neutral on device: p99 of frame budget 53.3%
against the baseline's 53.3%, or 49.4% on the run itself, which is inside
the run-to-run content variance these device traces carry. It is worth
having for full-motion video rather than for gameplay: PS1 FMV is 24-bit
source material and a 16-bit output path crushes it.

Resist the temptation to read the core-time drop (5.765ms to 5.276ms
median) as the option making the core faster. It cannot be: the RGB565
unpack pass this option removes lives in Cabinet's own upload, not inside
`retro_run`, and p95 was 7.540 against 7.528, which is the same number.
That is two runs sitting on different parts of the demo, the same trap the
mGBA "regression" was.

**Not shipped, and the reason is a missing measurement rather than a bad
one.** 2x internal resolution IS shipped, and rgb32 measured fine on its
own, but the two together were never measured: the bench had them
compounding (2.40x combined against 1.68x for the resolution alone), the
device run that would have settled it was refused because the iPhone
auto-locked again, and stacking two changes on the strength of two separate
measurements is exactly the reasoning this pass exists to avoid. One
260-second run on an unlocked phone closes it:

    sh tools/bench/wave2.sh 322 pcsxReARMed psx_2x_rgb32 \
      "pcsx_rearmed_neon_enhancement_enable=enabled;pcsx_rearmed_rgb32_output=enabled" 260

Note on PS1 internal resolution, which **was** taken: the macOS bench put it
at 1.68x core time, which extrapolated to roughly 90% of frame budget and
looked unaffordable. The device disagreed and the device was right: 53.3%
to 64.4% p99.

The explanation recorded here at the time was that core-time ratios do not
transfer to budget percentages when the cost lands in the tail. That was
wrong, and it was corrected on 2026-08-20. The bench was hashing every frame
inside the window it used to time emulation, so it was charging the core for
its own work: measured on FCEUmm, 0.115ms of emulation against 0.228ms of
hashing. Worse for this particular comparison, the hash cost scales with the
frame, so doubling the internal resolution roughly quadrupled the harness
overhead at the same time as it raised the real cost. That is why the ratio
came out inflated in the wrong direction rather than merely large.

The lesson to keep is narrower than the one first written down: an instrument
that shares a stopwatch with the thing it measures will mislead you most
exactly where the thing you changed also changes the instrument's own cost.
The device did not overrule the Mac here. The Mac was measuring itself.

## Not attempted, with reasons

**Integer or sharp scaling.** Cabinet aspect-fits with a nearest sampler, so
a 256-pixel-wide NES image scaled onto a 1179-pixel screen produces unevenly
sized pixels, a real and objective scaling artifact. Fixing it means
touching `NativePlayerRenderer`'s sampler or default shader, which every one
of the fourteen cores runs through, N64 and Dreamcast included. Out of
bounds for this pass by the blast-radius rule; worth its own scoped piece of
work.

**Anisotropic filtering, MSAA.** Neither applies. Twelve of these cores are
software rasterisers handing over a finished framebuffer, and the two with a
real GPU context are the two excluded systems.
