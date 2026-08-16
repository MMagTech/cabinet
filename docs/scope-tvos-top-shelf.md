# tvOS top shelf

Status: built 2026-08-16, not yet seen on real hardware. tvOS only;
nothing here changes iOS.

Where it lives: `RommAppTopShelf/` is the extension target,
`RommAppTV/TVTopShelfWriter.swift` is the app's side of it, and
`RommAppTV/TVDeepLink.swift` handles being launched from the shelf.
`RommAppTopShelf/TopShelfSnapshot.swift` is the one file both processes
compile.

## Why

When Cabinet sits in the top row of the Apple TV home screen, the large
area above it belongs to Cabinet, and today it shows one static picture
of a controller forever. The honest content for that space is the same
thing Home already leads with: the games you played recently, their own
box art, one press back into one of them. It is the difference between
an app that was ported to the TV and one that lives there.

## What ships

A row of recent games above the app grid, each one their own cover art.
Pressing Play on a focused game boots it. Selecting it opens that game's
launch screen instead, where the save states are. Nothing paired and
nothing played both fall back to the static image already in the asset
catalog.

## The extension

Top shelf content comes from a separate app extension
(`TVTopShelfContentProvider`, extension point `com.apple.tv-top-shelf`),
not from the app. It is a second process, launched by the system
whenever the home screen wants content, including when the app has not
run since the Apple TV booted.

New to this project, so the parts worth stating plainly:

- New target, `CabinetTopShelf`, embedded in `RommAppTV`. Bundle id must
  be prefixed by the containing app's: `com.mmagtech.Cabinet.topshelf`
  for Release, `com.mmagtech.CabinetDev.tv.topshelf` for Debug, matching
  the two ids the tvOS app already uses.
- Automatic signing, same team, so the two new app ids get provisioned
  the same way the existing four targets are. The app group below is a
  capability on both the tvOS app and the extension, which means it also
  has to exist on the developer portal once.
- It rides inside the app bundle under `PlugIns/`, so the release process
  in `CLAUDE.md` does not change: archive with `CODE_SIGNING_ALLOWED=NO`,
  copy the `.app` into `Payload/`, zip it as an unsigned `.ipa`. Worth
  confirming on the first build that the extension actually made it into
  the archive rather than assuming it did.
- The extension compiles none of the app's own code. Not `Session`, not
  `RommClient`, not the models, not a single core. It reads a small file
  and hands back items. Everything it does not link is memory it does not
  spend and a way it cannot fail.

## Where its data comes from: the app group, not the network

Decided: the app writes a snapshot into a shared app group container, the
extension only ever reads it. The extension makes no network calls at
all.

Refetching from RomM was the alternative and it loses on four separate
counts, any one of which would be enough:

1. The extension runs when the home screen wants it, which is routinely
   before anything is signed in this boot and while nobody is looking at
   the app. A self hosted RomM server is exactly the kind of server that
   is asleep, moved, or off. A shelf that goes blank because the server
   in the basement is rebooting is worse than one that shows what you
   played yesterday.
2. It would need the pairing token in a second process, which means a
   shared Keychain access group and a copy of the credential somewhere
   new. This project already dropped a whole feature over moving that
   token somewhere it did not need to be, see
   `scope-icloud-pairing-continuity.md`. Zero reason to spend it here.
3. Multi profile. `TVProfileStore` keys each profile's token by profile
   id in its own Keychain service, and the extension has no business
   resolving which profile is active. The app knows; let it just say.
4. Extension memory and time budgets are far below an app's. Downloading
   and decoding several covers is precisely the work that gets an
   extension killed mid answer.

### The tvOS storage constraint, which shapes the whole design

On tvOS, only `Library/Caches` inside the shared container is writable,
and everything there is purgeable by the system at any time. Real
persistent storage on this platform is 500KB of `UserDefaults` and
nothing else. That is the same constraint the account switcher already
lives under.

So the snapshot is split:

- **The list** goes in a shared `UserDefaults` suite: for each game, its
  rom id, its title, and the filename of its poster. Eight entries is
  one or two kilobytes, comfortably inside the 500KB budget the app
  shares. This is the part that must not vanish.
- **The posters** go in `Library/Caches` inside the group container.
  Purgeable, and that is acceptable: the app rewrites them every time it
  foregrounds, so a purge heals itself the next time anyone opens
  Cabinet. In the meantime the extension skips any game whose poster is
  missing, rather than drawing a stand-in for it. A row with holes
  punched in it looks broken in a way a shorter row does not, and if
  every poster is gone the shelf falls back to the static brand image,
  which is a better answer than a row of grey rectangles.

Any change to what that snapshot holds needs the usual non destructive
migration path, but it is cheap here: a snapshot is derived data, and the
right migration for a shape the extension does not recognise is to ignore
it and let the app rewrite it. The extension should never crash on a
snapshot it cannot read, it should return no content.

### Who writes it, and when

A tvOS only `TVTopShelfWriter`, called from `RommAppTV.swift` when the
app becomes active and after a play session ends, fetching recents
itself through `Session` the same way Home does, including
`waitForPendingPlayReport()` so the game just played sorts first rather
than under the one before it.

Deliberately not written from `HomeView`'s own `load()`, which already
has the list in hand. Two reasons: `HomeView.swift` is shared with iOS
and this is tvOS only work, and Home is not guaranteed to be visited,
so a session spent entirely in Library and the player would leave the
shelf stale. The cost is one extra recents call per foreground, eight
items, which is nothing next to fetching cover art.

Two cases that must wipe rather than rewrite:

- **Signing out.** The snapshot goes with it. Leaving a signed out
  Apple TV showing a row of somebody's games is the wrong answer.
- **Switching profiles.** The shelf is whoever is active. `TVProfileStore.activate`
  clears the snapshot, then the writer refills it from the new profile.
  Without this the household's shelf keeps showing the previous person's
  games until the app happens to foreground.

Worth saying out loud, since it is inherent rather than fixable: the top
shelf is visible to anyone in the room with no authentication at all.
Game titles and covers of the active profile are on the home screen.
That is what the feature is, and it is the same information the TV shows
anyway the moment anyone opens the app, but the profile switch wipe
above is what keeps it honest.

## The row, not the banner

Decided: sectioned content, one collection titled "Recent", poster
shape.

Poster is 404 by 608 with a safe zone of 380 by 570, which is box art at
almost exactly the shape RomM already stores it in. Roughly six games fit
across, the focused one lifts and names itself, and it is recognisably
Home's own Recent shelf living on the home screen. One app, two surfaces,
same language, which is the drift rule in `CLAUDE.md` being satisfied
rather than worked around.

Inset banner loses because Cabinet has no wide art for any game. The
inset shape is 1940 by 692 and everything either side of a portrait cover
would be invented to fill it, one game at a time, with the game you
played on Tuesday four swipes away.

Carousel loses harder and for the same reason. It wants a full 1920 by
1080 image per item that fills the entire home screen behind the app
grid. Cabinet could generate one from a blurred cover, which is exactly
the ambient treatment `TVGameLaunchView` already uses, but that
treatment earns its place sitting behind that one game's own screen.
Blown up to own the whole home screen it becomes the app's loudest
surface and every pixel of it is fabricated. Apple's own guidance for
carousel is featured editorial content with real key art, refreshed
regularly. "What you played recently" is a shelf.

Not reopening this by reaching for save state screenshots as banner art
either. Home deliberately stopped mixing captured game frames with box
art, for stated reasons, and this would reintroduce exactly that.

### Cover art, concretely

Every game gets two real files, 404 by 608 and 808 by 1216, rendered by
the app rather than copied. Copying the raw cover bytes was the first
plan and it was one file short of workable: games with no art at all,
which is most of arcade, need something drawn for them anyway, and once
there is a renderer the cost of using it for everything is nothing.
RomM's covers run about 2:3 and the poster shape is 2:3, so a real cover
fills its frame with almost nothing cropped. Games with no art get the
same titled placeholder `CoverImage` already draws, on the app's own
panel colour.

Two files rather than the same file handed to both traits: the trait
says what an image *is*, not what size is wanted, so pointing
`screenScale1x` at a 2x image tells the system something untrue about
it. Along the same lines the renderer pins its format scale to 1, since
the default is the screen's own scale and would quietly double the pixel
dimensions of what gets written.

The poster filename carries a hash of the cover path, and RomM's cover
paths already carry the timestamp of the last artwork change, so new art
changes the filename and rewrites itself while unchanged art costs
nothing. That is what keeps the steady state at zero image requests: only
a game whose art is new, or whose poster the system purged, is fetched at
all.

Both scales are set with `setImageURL(_:forTraits:)`. The URLs are file
URLs in the group container, which is why the container is required
rather than merely convenient: the system reads those files from outside
both processes.

## Pressing a game

Both actions are a `TVTopShelfAction` carrying a URL, which launches the
app with it. This means a URL scheme, which the app does not have today:
`cabinet://play?rom=<id>`, registered in the tvOS target's `Info.plist`.

The two actions do different things on purpose, which is what they are
for:

- **Play button** goes straight into the game. Prepare and boot, showing
  download progress if the ROM is not already on the device. This is the
  "one press back into it" the feature exists for.
- **Select** opens that game's launch screen, `TVGameLaunchView`, where
  "Continue from" lists the save states. Someone who wants to resume from
  Tuesday's state rather than restart wants this, and it is one more
  press to play from there.

Both are worth watching on real hardware. If the split reads as
unpredictable rather than as two deliberate doors, collapsing both onto
straight to play is the fallback, and the launch screen stays reachable
through the app itself.

Handling stays inside the tvOS target: `.onOpenURL` on the scene in
`RommAppTV.swift`, resolving the id through the existing
`RommClient.rom(id:)`, presenting `TVGameLaunchView` or going straight to
`TVPlayerView` in a `fullScreenCover`. No shared file needs to change for
any of this.

Edges that need answering rather than discovering:

- **Not paired when the link arrives.** The shelf should not have had
  items at all in that state, but a signed out session with a stale
  snapshot is reachable. Land on the normal setup flow and drop the
  link. Never queue it for after setup; by then it is a game somebody
  pressed a minute ago on a different account.
- **The rom is gone from the server.** `rom(id:)` fails, so land on Home
  with a plain message rather than an empty player.
- **The platform is not playable on Apple TV.** Should not happen, the
  writer filters to natively playable platforms before writing anything,
  but `TVGameLaunchView` already says so properly if it does.
- **A game is already running.** Deep linking into a second game while
  one is live has to go through the same exit path a quit does, not
  stack a second player on top of the first.

## Which games get on the shelf

Recents, filtered to platforms this Apple TV can actually play, using the
same gate `TVLibraryView` already applies. Recents come from the account,
not the device, so somebody who plays DS and PS2 on their phone has
recents that tvOS has no core for and no webview to fall back on. A shelf
item that leads to "this platform isn't supported on Apple TV yet" is a
broken promise on the home screen.

Eight items, matching `recentlyPlayed`'s own default, which comfortably
fills the visible row and leaves a little to scroll.

If that filter leaves nothing, the answer is the same as never having
paired: return no content, let the static brand image stand. No "Sign in
to Cabinet" item, no "Browse your library" tile. Everything on this shelf
is a game you can press play on, or the shelf is not there.

## Refreshing

The app calls `TVTopShelfContentProvider.topShelfContentDidChange()`
after writing a snapshot. It is a hint, not a command: tvOS refreshes
when it decides to. Nothing in the design should depend on the shelf
being current to the second, which it will not be.

## Confirmed on hardware, 2026-08-16

Running on a real Apple TV 4K, same evening it was built. The shelf
appears and lists recents with their cover art.

**The two actions differing is settled, keep it.** Select opens the
launch screen and Play boots straight in, and the reason it does not
feel like a detour is that the launch screen arrives with its Play
button already focused, so Select is press-press rather than press,
hunt, press. That was the one thing that would have sunk the split, and
tvOS's focus heuristic happens to get it right here without help. If a
future change to that screen's layout moves initial focus off Play,
this decision goes with it, so pin the focus explicitly rather than
quietly accepting two presses and a hunt.

Getting it onto the device needed one thing no amount of code could
supply: the App Groups capability added in Xcode on **both** the
RommAppTV and CabinetTopShelf targets. The cached wildcard provisioning
profile predates entitlements entirely, so every build fails with
"doesn't support the group.com.mmagtech.Cabinet App Group" until that is
registered once. That is a signing-account step, not a build flag.

Still unexercised, and only reachable by living with it:

1. How the arcade placeholder poster reads at shelf size, the one piece
   of art here the app invents rather than fetches.
2. That a profile switch clears the shelf before the next person's games
   arrive, the one failure here with a privacy edge.
3. Purge behaviour, which by definition only shows up after the system
   decides to reclaim the cache.

## Open questions

1. Whether the shelf should ever show anything other than recents.
   Favorites is the obvious second row and sectioned content supports
   several collections. Deliberately out of scope for a first pass:
   recents is the one the resume first principle already argues for, and
   a second row is a small addition once the first works.
