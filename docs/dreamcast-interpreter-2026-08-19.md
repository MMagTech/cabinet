# Dreamcast interpreter session, 2026-08-19

The brief: Dreamcast still slows down in heavy scenes with audio breakup,
on both Apple TV (A15) and iPhone. Rendering was already exonerated; the
remaining deficit is the SH4 interpreter, measured at roughly 10.5 ns per
instruction on A15 heavy scenes against 3.4 on an M4. Constraints: no
JIT, no reduced emulated clock as the answer, no correctness sacrifice,
no speculative changes without measurement.

## 1. The owed ANGLE buffer-pool A/B: perf-neutral for Flycast

Four interleaved 5.5 minute runs on the fan-cooled Living Room TV, same
app binary, only the libGLESv2 framework swapped between the pre-fix and
fixed (retirement stamp) builds. Readback p50 per run: 3.127, 3.127,
3.123, 3.121 ms. Frame rate, run_ms percentiles, interpreter ns per
instruction and instruction mix identical across arms. The N64 fix can
ship for both GL cores with no Dreamcast asterisk.

Two rig facts came out of this. First, the OS thermal label flaps
between nominal and serious on the fan-cooled box while the calibration
loop stays flat near 1.97 ms, so cal_ms is the only trustworthy throttle
signal now. Second, the cooled box resolves cross-arm deltas under one
percent; the old plus-or-minus seven percent ceiling is gone.

## 2. The predecoded-block interpreter

New in the spikes Flycast tree (sh4_interpreter.cpp, sh4_cycles.h/cpp),
runtime-toggleable via CAB_PREDECODE in the environment so one binary
carries its own baseline.

Design, chosen for correctness first: straight-line instruction runs are
decoded once into 16-byte records of handler pointer, raw opcode,
execution unit, issue cycles and flags. The existing opcode handlers are
called unchanged with the same arguments, so all runtime FPSCR.PR/SZ
behaviour is untouched (verified in source: every FPU handler re-checks
FPSCR at execution). Cycle accounting runs the identical dual-issue
state machine with decode-time descriptor fields, sharing state with the
classic path, so the charge sequence is byte-identical. Blocks end at
any WritesPC opcode, cover main RAM with the MMU off only, and are
re-verified against RAM on every entry by comparing the source bytes,
the same guard the upstream dynarec emits for unprotected pages and the
only self-contained scheme that also catches GD-ROM DMA and HLE BIOS
memcpy code loads, which never pass through the WriteMem hooks. Delay
slots of taken branches execute from a predecoded record as well.

What it removes per instruction: the fetch, the OpPtr table load, the
OpDesc pointer chase and isMemOp lookup inside countCycles. What it
keeps: the indirect handler call, the memory access path, the per-record
slice check.

Evidence, Mac lab (M4, Crazy Taxi 2, interleaved off/on):

- In-game interpreter cost 4.7 to 5.2 ns per instruction down to 3.7,
  about 1.30x. Full-run 1.25x with the later increments.
- Retired instruction streams bit-identical off versus on, per-dump
  counts equal to the instruction, mix identical, zero entry-check
  failures.
- Increments measured separately: delay-slot records neutral on M4 but
  strictly remove work; the inline entry check (replacing the libc
  memcmp call) won both interleaved pairs.

Evidence, Apple TV A15 (fan-cooled, ABAB via devicectl launch -e):

- In-game band, workload-matched medians: 7.16 and 7.12 ns per
  instruction off, 6.55 on, about 1.09x. Boot and menu spin loops 8.49
  and 8.43 off, 7.07 on, about 1.20x.
- run_ms p99 improved from 18.8 and 17.4 to 16.1 ms; fps steady; the on
  arm's variance is far tighter.
- The entry check caught four real code reloads mid-game and the game
  ran through them correctly.

Verdict: the M4 gain does not fully transfer. The A15 spends
proportionally more in what predecode cannot remove: the indirect
dispatch call, the data-memory chain (an un-inlinable global function
pointer call per access, 43 to 57 percent of the mix), and handler
bodies. Extrapolated, heavy scenes go from 10.5 to roughly 9.6 ns per
instruction against a 1.54x requirement for realtime. Predecode closes
about a fifth of the gap, is strictly correct, and reduces frame-time
tails. The next evidence-backed lever is the memory path, then threaded
dispatch.

## 3. Sh4Clock wired into the interpreter

The Dreamcast CPU speed setting never did anything: Sh4Clock was read
only by the dynarec decoder, which is compiled out. The interpreter now
scales its per-instruction charge by 200 over Sh4Clock in 8.8 fixed
point with remainder carry, the same reweighting the dynarec applies per
block. At the default of 200 the factor is exactly the compile-time
ratio, the accumulator never carries, and the charge sequence is
byte-identical, verified on both the lab and the device against the
old core's instruction accounting. The scale refreshes once per
timeslice so option changes take effect live, and ResetCache now
refreshes it and drops decoded blocks.

Lab validation: clk300 and clk400 scale emulated instruction throughput
1.43x and 1.86x with flat per-instruction cost, audio rate unchanged.
The M4 holds 1.66x realtime at clk400, which is the authentic 200 MHz
machine.

NativeCoreOptions: the tvOS default moved from 150 to 200. The 150 was
tuned against a core that ignored the option, so every device has
actually been running 100 MHz effective; 200 preserves that behaviour
now that the dial is real. Re-tune per platform from measurements on the
wired core.

## 4. The memory-path variants (verdict pending on device)

After Marcus's visual pass came back clean, the predecoder gained
decode-time fast variants of the sixteen hottest integer memory
handlers, with the RAM access inlined behind the same address test the
fetch fast path uses; anything that is not main RAM falls back to the
classic path, so device registers, VRAM and AICA traffic behave
identically. The original handlers are untouched and the variants are
gated on CAB_PD_FASTMEM.

The M4 measured no gain (3.56 versus 3.57 ns per instruction on the
clean interleaved pair, instruction streams bit-identical). That is not
the final word: the M4 also overpredicted predecode's transfer, and its
deep out-of-order window is exactly the hardware that hides a dependent
pointer-load, indirect-call, page-walk chain. The A15 answer takes two
5.5 minute runs on the TV whenever it is free.

## 5. The night queue on the TV

Three campaigns ran unattended once the TV freed up, all on the
fan-cooled box, all ANGLE, all with the calibration loop confirming
zero thermal throttling.

The memory-path variants earned their keep on the A15 where the M4
could not see them: 6.57 down to 6.45 ns per instruction in the
workload-matched in-game band, both interleaved pairs agreeing. About
1.8 percent, taking the composite interpreter gain on the A15 to
roughly 1.11x.

The entry-check ablation answered its question emphatically: with the
check skipped, Crazy Taxi 2 wedges deterministically about forty
seconds in, both attempts, hung in a wait loop after the first real
code reload executed stale blocks. The check is functionally mandatory
and its cost question is closed.

The clock-ceiling sweep, with the full stack: audio holds 1.000 at the
default 100 MHz effective, 0.991 at 125, then degrades: 0.944 at 150,
0.833 at 175, 0.830 at authentic 200. The A15's clean ceiling is the
default, with 125 MHz effective borderline; these are attract-mode
numbers, and real play runs harsher, so the shipped default stands.
Marcus's iPhone session at authentic 200 MHz in real play held 83 to 96
percent audio, so the phone's ceiling is meaningfully higher and still
unmeasured.

Two measurement traps surfaced and are now guarded: a hung game leaves
the app running and the next launch can fail to displace it, and a
stalled launch plus a pull silently returns the previous run's
full-size trace. Row counts do not catch the second; an md5 compare
against the previous pull does.

## 6. Loose ends

- The intermittent launch-path stall recurred once (header-only trace,
  relaunch fine). Second occurrence ever, both after a terminate plus
  immediate relaunch. Worth a counter if it recurs again.
- devicectl copy-to cannot overwrite an existing container file. The
  first device ABAB silently ran all four arms off because of this; the
  reliable toggle is environment injection via devicectl launch -e.
- The iOS core archive is rebuilt with everything above but has not been
  installed or tested on the iPhone.
- Marcus's eyes on a predecode build are still owed before any of this
  is called done, per the standing rule that headless numbers prove
  speed, not picture.
- tools/lab/dclab.c gained CAB_OPT_key=value environment overrides for
  any core option.
