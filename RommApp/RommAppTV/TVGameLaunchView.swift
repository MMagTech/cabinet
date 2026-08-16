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

    @State private var states: [GameState] = []
    @State private var loadingStates = true
    @State private var preparing = false
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var launch: Launch?

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

                    if let platform {
                        playButton(platform: platform)
                        statesSection
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
            guard autoStart, platform != nil else { return }
            await play(stateData: nil)
        }
        .fullScreenCover(item: $launch) { launch in
            TVPlayerView(rom: rom, core: launch.core, initialState: launch.initialState)
        }
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

    private var sortedStates: [GameState] {
        states.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    private func loadStates() async {
        states = (try? await session.states(romId: rom.id)) ?? []
        loadingStates = false
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
