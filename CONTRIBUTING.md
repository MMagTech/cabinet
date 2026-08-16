# Contributing to Cabinet

Thanks for helping. A few things keep contributions easy to review.

**If you use an AI assistant** (Claude Code, Cursor, Copilot or anything
else), point it at `CLAUDE.md` in the repository root before it writes code.
It carries the project's conventions and settled architectural decisions.
Contributions that ignore it will get asked to redo things, so it saves
everyone time.

**Work on `dev`.** Pull requests target `dev`, not `main`. `main` is the
release branch.

**Respect the platform boundary.** tvOS code is in `RommApp/RommAppTV/`,
iOS and shared code in `RommApp/RommApp/`. If your tvOS change touches a
shared or iOS file, say so in the PR description and explain why. Same in
reverse.

**Keep PRs small and focused.** One fix or feature per PR. Working software
over speculative design.

**Say so when a PR moves code between files.** If code moves to a new file
on one branch while someone fixes that same code where it used to live on
another, git merges both without a conflict and silently drops the fix.
Nothing shows up in the diff to notice. That is not hypothetical here: a
fix making the native player's audio true stereo landed hours after the
audio code had moved to a new file on another branch, the merge kept the
move and lost the fix, and every core played mono for five days before
anyone caught it. So call out moves in the PR description, and after
merging a branch that has been open a while, check that the changes it
brought in still exist where that code now lives.

**No new dependencies without discussion.** Open an issue first.
`URLSession` and Swift concurrency have been enough so far.

**Settled decisions stay settled.** The JIT boundary, the auth flow, and the
other decisions marked settled in `CLAUDE.md` and `docs/scope-v0.1.md` are
not up for relitigating in a PR. Open an issue if you think one genuinely
needs to change.
