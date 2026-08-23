# Handing a game to RetroArch

**Not planned, not committed, not scoped.** A user asked for it, the
mechanism turned out to be real and better documented than expected, and
the tradeoffs are sharp enough to be worth writing down before they are
forgotten. Nothing here is a decision.

Researched 2026-08-22 from RetroArch's own source rather than from
documentation, which does not cover this.

## The request

> I was wondering if the external RetroArch launching could be added using
> the `retroarch://topshelf?path=…` app url, in order to allow for more
> platforms to be played (Amiga, PSX…)

## What the mechanism actually is

RetroArch registers the `retroarch` URL scheme
(`pkg/apple/iOS/Info.plist`, url name `com.retroarch.url`) and parses
several forms in `openRetroArchURL:` in `ui/drivers/ui_cocoatouch.m`:

| URL | What it does |
|---|---|
| `retroarch://topshelf?path=…&core_path=…` | Loads that content with that core. **Both parameters are required**; it returns NO if either is missing. |
| `retroarch://start` | Foregrounds RetroArch, nothing else. |
| `retroarch://game/<filename>` | Launches a game by filename. |
| `retroarch://library?scheme=<callerScheme>` | Serialises RetroArch's whole library and hands it back by opening `<callerScheme>://retroarch?games=<base64url JSON>`. |

That last one matters more than the request does: RetroArch has
deliberately built a way for another app to enumerate its library and
round-trip a game back into a launch URL. Whoever wrote it was thinking
about exactly this kind of integration, so this is a conversation worth
having upstream rather than a hack against an unwilling app.

## Why it is not free

**Saves stop syncing, and that is the whole product.** Cabinet's model is
that saves and states live on your RomM server and follow you between
devices. A game launched into RetroArch writes its saves into RetroArch's
own directories and nothing ever uploads them. The user would gain
platforms and lose the thing that distinguishes Cabinet from simply
installing RetroArch.

**`core_path` is required**, so Cabinet would have to know RetroArch's own
core filenames per platform, and track them as RetroArch changes them, for
a code path that is awkward to test.

**File access is unverified.** Cabinet's downloads live in its own
sandbox and iOS does not let another app read that. Kept games are exposed
through the Files app (`UIFileSharingEnabled`), which may make this
workable, but nobody has confirmed RetroArch can actually open such a
path. **Check this before anything else**: if it cannot, the whole idea
stops here.

**It is one way.** You leave Cabinet and you are in RetroArch. No return,
no play-session reporting, no last-played, no resume card.

## Three framings, and which one to build

**Per-game, offered everywhere.** Rejected. Some games sync and others
silently do not, which is harder to explain than either extreme.

**A global setting that makes RetroArch the only launcher.** Coherent,
and the version originally considered. It fixes the inconsistency, since
anyone who enables it has chosen it knowingly. But it switches off
eighteen native cores, the arcade control panels, the Vectrex overlays,
the core options work, offline play and save sync all at once. That
serves someone who mostly wants RetroArch with a nicer browser, and they
already have RetroArch.

**Unsupported platforms only. This is the one worth building.** Offer it
solely where Cabinet cannot play a game itself. That answers the actual
request, Amiga and everything Cabinet will never carry a core for, while
changing nothing about the platforms it does support. Saves keep syncing
everywhere they sync today. The inconsistency becomes explainable in one
sentence: platforms Cabinet supports play here and sync, platforms it
does not are handed to RetroArch and do not.

It also fits machinery that already exists. `PlatformSupport.isSupported`
already knows exactly which platforms Cabinet cannot play, and those games
currently show as Unsupported with nothing but a download button.
Replacing a dead end with "Open in RetroArch" strictly improves a screen
that today only says no.

If a global "always prefer RetroArch" switch is ever wanted, it belongs
behind the same door: off by default, and honest in its own text that
saves stop syncing.

## Verified versus assumed

Verified by reading RetroArch's source: the scheme, all four URL forms,
that both `topshelf` parameters are required, and the loader it calls.

Not verified: whether RetroArch can read a file from Cabinet's
Files-exposed Documents directory, whether tvOS behaves identically to
iOS here, and whether `core_path` wants a full path or a bare core name.
