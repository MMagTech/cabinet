#if os(tvOS)
import SwiftUI

/// tvOS's launch screen, the scoped-down sibling of iOS's
/// `GameLaunchView`. That screen is 1,600-odd lines because it also
/// gathers webview-player choices (core picker, EmulatorJS backend,
/// firmware selection) and hands them to RomM's own player page through
/// localStorage. None of that applies here: tvOS has no webview player
/// (see CLAUDE.md's JIT boundary), and a platform resolves to exactly one
/// native core, so there is nothing to pick.
///
/// What is left is the part that actually matters on a TV: cover, title,
/// a Play button, and the save states you might want to jump back into.
struct TVGameLaunchView: View {
    let rom: Rom
    /// Starts preparing and booting the moment this appears, instead of
    /// waiting for the Play button. Only the top shelf's Play action
    /// sets this: pressing Play on the Home screen means play, so
    /// landing here on a Play button that then has to be pressed again
    /// would be one press too many for the one thing this whole feature
    /// exists to make quick. Its own Select action lands here normally,
    /// with the save states in reach.
    var autoStart: Bool = false

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var compatibility = Compatibility.shared

    @State private var states: [GameState] = []
    @State private var loadingStates = true
    @State private var preparing = false
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var launch: Launch?
    /// Mirrors NativeCoreChoice so the emulator row's label updates the
    /// moment it is clicked; the store itself is the source of truth.
    @State private var chosenCore: NativeCore?
    /// Whether this game has an emulator config worth offering to
    /// throw away. Drives the reset row's presence, so pressing it
    /// makes the row disappear, which is the confirmation.
    @State private var hasCoreSettings = false

    private struct Launch: Identifiable {
        let id = UUID()
        let core: NativeCore
        let initialState: Data?
    }

    private var canonicalSlug: String {
        rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
    }

    private var platform: NativePlatform? {
        NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug)
    }

    /// The platform this device is actually willing to boot: nil for a
    /// platform behind the experimental switch while the switch is off.
    /// Kept separate from `platform` above so the screen can tell "not
    /// supported here at all" apart from "supported, but you have to
    /// choose it", which get different sentences below.
    private var offeredPlatform: NativePlatform? {
        guard let platform, !platform.isExperimental || ExperimentalCores.enabled else { return nil }
        return platform
    }

    private var coverPath: String? {
        rom.pathCoverLarge ?? rom.pathCoverSmall
    }

    var body: some View {
        ZStack {
            // A real opaque backdrop, not decoration. A fullScreenCover on
            // tvOS does not paint one of its own, so without this the
            // screen underneath (Home, with its hero and both shelves)
            // shows straight through this one's gaps and the two read as a
            // single garbled screen (seen on real hardware 2026-08-11).
            //
            // Blurred cover art rather than flat black, because the same
            // art is already fetched for the panel beside it and this is
            // the ambient-backdrop treatment Home's own hero card already
            // uses: the game's own colours filling the space instead of a
            // slab of nothing.
            Color.black.ignoresSafeArea()
            // The explicit infinite frame matters: without it this sizes
            // to its own image dimensions rather than genuinely filling
            // the screen, and .fill content mode alone doesn't guarantee
            // full-bleed coverage if the frame offering it a size never
            // asked for one that large. The gap showed up as a second,
            // ghost-edged rectangle peeking out from behind the sharp
            // cover art beside it, not as a single obvious seam.
            CoverImage(path: coverPath, title: rom.displayName, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 60)
                .overlay(Color.black.opacity(0.55))
                .ignoresSafeArea()

            HStack(alignment: .center, spacing: 60) {
                CoverImage(path: coverPath, title: rom.displayName)
                    .frame(width: 340, height: 460)
                    .clipShape(.rect(cornerRadius: 16))
                    .shadow(radius: 24, y: 12)

                VStack(alignment: .leading, spacing: 20) {
                    Text(rom.platformLabel(source: .platformName, platformNames: session.platformNames))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(rom.displayName)
                        .font(.largeTitle.bold())
                        .lineLimit(3)

                    if let platform = offeredPlatform {
                        playButton(platform: platform)
                        statesSection
                        // Side by side as equal capsules, not stacked
                        // settings rows: RowFocusStyle is the full-width
                        // row treatment, and two of them at their own
                        // natural widths under a white pill read as
                        // mismatched grey blobs (Marcus, from a photo of
                        // the real screen). The capsule is this screen's
                        // own secondary-action shape.
                        HStack(spacing: 16) {
                            if platform.cores.count > 1 {
                                emulatorRow(platform: platform)
                            }
                            troubleRow
                        }
                    } else if platform != nil {
                        // Supported but gated: the core exists, the
                        // person just has not opted into it. Named
                        // rather than generic so the fix is one
                        // sentence away.
                        Text("This platform is experimental. Turn on Experimental cores in Settings > Emulation to play it.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    } else {
                        // Every platform tvOS can't run lands here: no
                        // native core exists for it, and unlike iOS there
                        // is no webview player to fall back to.
                        Text("This platform isn't supported on Apple TV yet.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
        .task { await loadStates() }
        // A separate task from the one above on purpose: booting must
        // not wait on the save state list, which is a second round trip
        // and is not needed to start a fresh run. Guarded on the
        // platform being playable here so an unsupported one still gets
        // the explanation rather than a silent nothing.
        .task {
            guard autoStart, offeredPlatform != nil else { return }
            await play(stateData: nil)
        }
        .onAppear { refreshCoreSettings() }
        .onChange(of: chosenCore) { _, _ in refreshCoreSettings() }
        .fullScreenCover(item: $launch) { launch in
            TVPlayerView(rom: rom, core: launch.core, initialState: launch.initialState)
        }
    }

    /// Marking a game as not working, always offered rather than waiting
    /// for the app to suggest it.
    ///
    /// iOS only surfaces its equivalent card once a game has crashed
    /// repeatedly, because there the deliberate path is a long-press menu
    /// in every list. Neither half of that reasoning holds here: tvOS has
    /// no such menu outside the Home shelves, and the crash counter only
    /// watches web-player deaths, which a natively played game never has.
    /// A Dreamcast game that runs badly but never crashes would therefore
    /// never offer anything at all, which is exactly the case this exists
    /// for. So it is a permanent row, and saying so is its whole job.
    ///
    /// The mark is per device (see Compatibility), which is the point on a
    /// TV: the same game may be perfectly playable on a phone with twice
    /// the headroom, and marking it here says nothing about there.
    /// The native emulator choice, shown only where a real one exists
    /// (arcade: FinalBurn Neo or MAME 2003-Plus). A click cycles rather
    /// than opening a picker: two options, and every other row on this
    /// screen is a single-press action, so a submenu would be the odd
    /// one out. Same choice store as iOS's launch screen, so the two
    /// launchers always agree on which emulator a game gets.
    @ViewBuilder
    private func emulatorRow(platform: NativePlatform) -> some View {
        let current = chosenCore ?? NativeCoreChoice.resolved(for: rom, platform: platform)
        Button {
            let cores = platform.cores
            let next = cores[((cores.firstIndex(of: current) ?? 0) + 1) % cores.count]
            NativeCoreChoice.remember(next, rom: rom, platform: platform)
            chosenCore = next
        } label: {
            Label("Emulator: \(current.displayName)", systemImage: "cpu")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .buttonStyle(TextFocusStyle())
    }

    /// Both remedies for "this game is not behaving", behind one
    /// capsule, because neither deserves equal billing with Play or
    /// with the emulator choice: one is a repair, the other is a
    /// report, and both are rare. Grouping them also puts them where
    /// somebody in trouble would actually look, rather than making
    /// them read three similar labels to find the right one.
    ///
    /// The marked state stays on the capsule's own face rather than
    /// hiding inside the menu: a game someone has flagged should say
    /// so without being opened.
    @ViewBuilder
    private var troubleRow: some View {
        let marked = compatibility.isMarked(rom.id)
        Menu {
            if hasCoreSettings, let core = runningCore {
                Button {
                    NativeLauncher.resetCoreSettings(romId: rom.id, core: core)
                    hasCoreSettings = false
                } label: {
                    Label("Reset emulator settings", systemImage: "arrow.counterclockwise")
                }
            }
            Button {
                compatibility.setMarked(!marked, romId: rom.id)
            } label: {
                Label(marked ? "Mark as compatible" : "Mark as incompatible",
                      systemImage: marked ? "checkmark.circle" : "exclamationmark.triangle")
            }
        } label: {
            Label(marked ? "Marked incompatible" : "Troubleshoot",
                  systemImage: marked ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .buttonStyle(TextFocusStyle())
    }

    @ViewBuilder
    private func playButton(platform: NativePlatform) -> some View {
        Button {
            Task { await play(stateData: nil) }
        } label: {
            HStack(spacing: 12) {
                if preparing {
                    ProgressView()
                    Text(progress > 0 ? "Downloading \(Int(progress * 100))%" : "Preparing")
                } else {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
            }
            .frame(minWidth: 240)
            .padding(.vertical, 6)
        }
        .disabled(preparing)
    }

    @ViewBuilder
    private var statesSection: some View {
        if !states.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Continue from")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        // Newest first: the most recent state is the one
                        // most likely wanted, same ordering iOS's own
                        // state list uses.
                        ForEach(sortedStates) { state in
                            Button {
                                Task { await play(state: state) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(RommDate.relativeLabel(state.updatedAt))
                                    // Never the filename: RomM auto-names
                                    // every upload, so it is a name nobody
                                    // chose (see RommDate's own note) and
                                    // reads as raw machine output on a TV.
                                    // A clock time instead, which is the
                                    // one thing that actually tells two
                                    // same-day states apart.
                                    if let exact = exactLabel(state.updatedAt) {
                                        Text(exact)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(minWidth: 220, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                            // A small radius against a two-line block
                            // left long, straight vertical edges either
                            // side, which is exactly the hard-line look
                            // this glass treatment exists to avoid.
                            .buttonStyle(TextFocusStyle(cornerRadius: 26))
                            .disabled(preparing)
                        }
                    }
                    // Vertical-only padding here left the first and last
                    // cards with no horizontal room to grow into: focused,
                    // a card scales up and gains a glass background, and
                    // with zero slack at the row's own edges that growth
                    // got clipped by the ScrollView's bounds, seen as a
                    // hard vertical line that sliced focused entries at
                    // the edges of "Continue from" specifically.
                    .padding(.vertical, 8)
                    .padding(.horizontal, 20)
                }
            }
        } else if loadingStates {
            ProgressView()
        }
    }

    private func exactLabel(_ raw: String?) -> String? {
        guard let date = RommDate.parse(raw) else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The core a Play press will actually run, for filtering below.
    private var runningCore: NativeCore? {
        guard let platform = offeredPlatform else { return nil }
        return chosenCore ?? NativeCoreChoice.resolved(for: rom, platform: platform)
    }

    private var sortedStates: [GameState] {
        // Only states the running core wrote: another emulator's state
        // hangs retro_unserialize forever rather than failing, so a
        // foreign state in this list was a frozen TV one press away.
        // Recomputed when the emulator row changes, so switching cores
        // swaps the list to that core's own states.
        states
            .filter { $0.emulator == runningCore?.emulatorTag }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    private func loadStates() async {
        states = (try? await session.states(romId: rom.id)) ?? []
        loadingStates = false
    }

    /// Recomputed rather than cached across launches: the core can
    /// change under the emulator row, and each core keeps its own
    /// settings folder.
    private func refreshCoreSettings() {
        guard let core = runningCore else { return }
        hasCoreSettings = NativeLauncher.hasCoreSettings(romId: rom.id, core: core)
    }

    private func play(state: GameState) async {
        guard let bytes = try? await session.stateContent(state) else {
            error = "Couldn't fetch that save state."
            return
        }
        await play(stateData: bytes)
    }

    private func play(stateData: Data?) async {
        preparing = true
        error = nil
        progress = 0
        do {
            let core = try await NativeLauncher.prepare(rom: rom, session: session) { fraction in
                progress = fraction
            }
            preparing = false
            launch = Launch(core: core, initialState: stateData)
        } catch {
            preparing = false
            self.error = error.localizedDescription
        }
    }
}
#endif
