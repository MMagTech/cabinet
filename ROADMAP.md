# Roadmap

Where Cabinet is headed. This is not a changelog, see
[Releases](https://github.com/MMagTech/cabinet/releases) for what has
already shipped. Nothing here is a promise or a deadline, this is a
weekend project worked on as time allows, but it is the real direction,
not a wishlist that gets ignored.

If something here interests you, or you want to pick one up, open an
issue or a discussion first so the approach can be talked through before
any code gets written.

## Being explored

Not committed, not scoped, real conversations that happened and are
worth having in the open.

- **A companion screen for iPhone over wired HDMI.** iPhones with
  DisplayPort support (most current models, notably not iPhone Air,
  16e, or 17e) can drive an external display with content different from
  what is on the phone itself, the same trick Apple's own Photos app
  uses. The idea: plug into any TV, gameplay renders there, the phone
  becomes a real second screen, cover art and browsing while idle, a
  "now playing" view during a game, closer to a console companion app
  than a remote. Layout and interaction are entirely undecided.
- **Preferring the local network over the public internet.** If Cabinet
  and your RomM server are on the same LAN, there's no reason to route
  requests out through the public internet and back. The idea is a
  second, optional local address you can set once, used automatically
  when reachable. Real side benefit: local downloads aren't bottlenecked
  by your home connection's upload speed the way a round trip through
  the public address is.
- **A native touch control restyle.** The current on-screen controls are
  functional but read a little flat next to the rest of the app. A
  restyle direction has been discussed, not built.
- **A real loading screen on tvOS for large downloads.** Right now the
  Play button's own label just turns into a percentage while a native
  game downloads, on a short game that can flash by in under a second.
  The idea is a proper full-screen moment for genuinely large
  downloads, small ones would keep today's quick inline behavior. Not
  settled whether to build it at all, let alone how.

## Known gaps

Real, acknowledged holes, not yet started.

- **Five platforms have no dedicated touch control layout**: Amiga CD32,
  Atari Jaguar, Neo Geo AES/MVS, Philips CD-i, Virtual Boy. They fall
  back to a generic layout today.
- **No native autosave.** Native play only resumes from an explicit save
  state, not automatically on quit or backgrounding, unlike the web
  player.
- **PC Engine's 2-button vs. 6-button controller mode** isn't wired up
  to its touch layout yet, even though the core supports it.
- **PS1 and Saturn multi-disc games aren't supported**, and whether they
  should be is genuinely undecided, it would need real `.m3u`-style disc
  swapping support, not just a missing feature flag.

## Not planned right now

Named explicitly so it doesn't get re-asked without new information.

- **iCloud sync for settings.** No confirmed real need yet.
