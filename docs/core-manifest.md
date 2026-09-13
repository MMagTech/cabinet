# The core manifest, and what it recovered

`docs/core-manifest.json` records the upstream revision of every emulator
core Cabinet ships. Written 2026-09-13.

## Why it exists

`tools/build-core.sh` and the per-core build scripts clone upstream with
`git clone --depth 1` and record the commit nowhere. The built `.a`
archives embed no version either, which was checked rather than assumed:
`strings` over the tvOS Gambatte and Snes9x archives returns core option
text and nothing resembling a revision. And `spikes/` is gitignored.

So until this file, the revisions behind the shipping apps existed in
exactly one place, the working trees on one Mac. A wipe of that machine
would have made the App Store build unreproducible.

It matters beyond Cabinet. CabinetOS has to build the same cores at the
same revisions or save states will not load across devices.

## What was recovered

Twenty-five cores, from fifty-four checkouts. For each: the repository,
the commit per platform, submodule pins where the clone was recursive,
the systems it serves, the build arguments each platform passes, and the
in-flight source patches that apply.

Two recoveries were not straightforward:

**PCSX2** had been cloned from a local path,
`spikes/ps2-jitless/arm64-fork`, which no longer exists. Its true
upstream was recovered as `isztldav/pcsx2` and commit `c89cb8ae` was
confirmed present there through the GitHub API.

**Game & Watch's iOS tree** has no `.git` at all. Its revision was
recovered by content: the tree is byte-identical to the Mac checkout
apart from build output, so it is `91d599b9`.

**PCSX2's dependencies** turned out not to be a gap. They are pinned
release tarballs with SHA256s in `spikes/cores/pcsx2-deps/src/SHASUMS`,
so they are fully reproducible and are recorded as versions.

## Finding 1: eleven cores ship different revisions to iOS and macOS

This is live in the apps that ship today, not a risk.

`build-core.sh` makes a separate checkout per platform and clones only
when the directory is absent, so each platform froze at whatever upstream
HEAD was on the day that platform was first built. Where those days were
weeks apart, the revisions are weeks apart.

| core | iOS | macOS |
|---|---|---|
| beetle_pce_fast | `b211204c` | `2f623abd` |
| beetle_saturn | `56d09e6d` | `ed549bda` |
| beetle_vb | `3f53a40b` | `83ed4260` |
| fceumm | `b5e35665` | `236ccdfc` |
| gambatte | `96174369` | `d9d6cd06` |
| genesis_plus_gx | `84fcf2ec` | `a7985a9c` |
| mame2003_plus | `93159c0c` | `21256d24` |
| pcsx_rearmed | `da2cb8ec` | `ba61a4fd` |
| picodrive | `6248b51f` | `733c711a` |
| prosystem | `363b6dfb` | `8a880142` |
| snes9x | `ed750a49` | `890b5d44` |

For beetle_vb and mame2003_plus, tvOS matches iOS rather than macOS.

pcsx_rearmed diverges on a second axis as well: its `frontend/libpicofe`
submodule is `dd11f2d7` on iOS and `6a4473cc` on macOS.

Whether any of these revision gaps actually changes a save state format
is not established here. Recording them is the point; deciding what to do
about them is not this file's job and was deliberately not done.

## Finding 2: eleven tvOS revisions are unrecoverable

These cores ship a tvOS library whose per-platform checkout no longer
exists on the build Mac:

gambatte, mgba, genesis_plus_gx, beetle_pce_fast, snes9x, fceumm,
beetle_ngp, prosystem, picodrive, pcsx_rearmed, beetle_saturn.

Their `commit` is null in the manifest rather than guessed. The one piece
of evidence that survives is when each built library was committed, which
bounds the build date: 2026-08-10 for gambatte and mgba, 2026-08-20 for
the other nine. That second date matches the tvOS archive rebuild
recorded on 2026-08-20.

That bound is not a revision and must not be treated as one. A checkout
created weeks before a rebuild still carries its original HEAD, because
`build-core.sh` clones only when the directory is absent, so the build
date does not imply the revision.

Three cores are unaffected because their builder uses one source tree
with separate `build-<platform>` directories rather than a checkout per
platform: flycast, ppsspp and fbneo. One revision covers all their
platforms, and it is recorded.

## Also worth knowing: unscripted source edits

Separate from the revisions, some working trees carry local edits that no
build script reproduces, so re-cloning at the recorded commit will not
reproduce what shipped. Flycast is the significant one, with roughly 760
lines across five files including a predecode cache in
`sh4_interpreter.cpp` and Sh4Clock wiring in `sh4_cycles.h`, all marked
`Cabinet:` in comments. mupen64plus and FBNeo carry smaller unscripted
edits.

The manifest records the revisions. It does not capture those edits.
Doing that is separate work and has not been done.
