import SwiftUI

/// The screen between picking a game and playing it, built natively.
///
/// RomM's own player page already does this job, and the game itself still
/// runs there. What this replaces is only the presentation: the choices are
/// gathered here in a screen that follows iOS conventions and lays out for
/// the shape of the display, then handed to RomM through the same
/// localStorage keys its page reads on load.
///
/// That is the whole coupling. Nothing here reimplements core selection, ROM
/// streaming, save handling or emulation. If a future RomM renames a key, the
/// value is ignored and its page falls back to its own defaults, which is
/// exactly the behaviour before this screen existed.
struct GameLaunchView: View {
    let rom: Rom

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("com.mmagtech.RommApp.useRommPlayerScreen") private var useRommScreen = false

    @State private var cores: [String] = []
    @State private var selectedCore: String?
    @State private var firmware: [Firmware] = []
    @State private var selectedFirmware: Firmware?
    @State private var saves: [GameSave] = []
    @State private var states: [GameState] = []
    @State private var selectedSave: GameSave?
    @State private var selectedState: GameState?
    @State private var loading = true
    @State private var playing = false

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ScrollView {
                if landscape {
                    // A short wide screen has width to spare and almost no
                    // height, so the option cards sit side by side rather
                    // than stacking into a column that needs scrolling.
                    // Identity and the primary action stay together on the
                    // left, where the eye starts.
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 12) {
                            cover(maxWidth: 140)
                            titleBlock(centred: true)
                            playButton
                        }
                        .frame(width: 190)

                        optionsGrid
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 20) {
                        cover(maxWidth: 200)
                        titleBlock(centred: true)
                        playButton
                        options
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") { dismiss() }
            }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $playing) {
            PlayerView(rom: rom, launch: launchChoices)
        }
    }

    // MARK: Pieces

    private func cover(maxWidth: CGFloat) -> some View {
        CoverImage(path: rom.pathCoverLarge ?? rom.pathCoverSmall, title: rom.displayName)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxWidth: maxWidth)
            .clipShape(.rect(cornerRadius: 14))
            .shadow(radius: 10, y: 5)
    }

    private func titleBlock(centred: Bool) -> some View {
        VStack(alignment: centred ? .center : .leading, spacing: 4) {
            Text(rom.displayName)
                .font(.title2.bold())
                .multilineTextAlignment(centred ? .center : .leading)
            Text(rom.platformDisplayName ?? rom.platformSlug)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
    }

    private var playButton: some View {
        Button {
            // Remember the choice, so the next launch of this game, and the
            // next game on this platform, starts where this one left off.
            LaunchChoices.remember(core: selectedCore, for: rom)
            playing = true
        } label: {
            Label(selectedState != nil || selectedSave != nil ? "Resume" : "Play",
                  systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
        }
        .buttonStyle(.borderedProminent)
        .disabled(loading)
    }

    /// Landscape only: cards flow into as many columns as the width allows,
    /// so two or three of them do not become a scrolling column.
    @ViewBuilder
    private var optionsGrid: some View {
        if loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading options").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                if cores.count > 1 { coreCard }
                if !firmware.isEmpty { firmwareCard }
                if !states.isEmpty || !saves.isEmpty { resumeCard }
            }
        }
    }

    @ViewBuilder
    private var options: some View {
        if loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading options").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 14) {
                if cores.count > 1 { coreCard }
                if !firmware.isEmpty { firmwareCard }
                if !states.isEmpty || !saves.isEmpty { resumeCard }
            }
        }
    }

    private var coreCard: some View {
        LaunchCard(title: "Emulator", systemImage: "cpu") {
            Picker("Emulator", selection: $selectedCore) {
                ForEach(cores, id: \.self) { core in
                    Text(CoreCatalog.displayName(core)).tag(Optional(core))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            if let selectedCore, let note = CoreCatalog.note(selectedCore) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(selectedCore == "mame2003" ? .orange : .secondary)
            }
        }
    }

    private var firmwareCard: some View {
        LaunchCard(title: "BIOS", systemImage: "memorychip") {
            Picker("BIOS", selection: $selectedFirmware) {
                Text("None").tag(Optional<Firmware>.none)
                ForEach(firmware) { item in
                    Text(item.fileName).tag(Optional(item))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resumeCard: some View {
        LaunchCard(title: "Resume from", systemImage: "clock.arrow.circlepath") {
            // States are greyed out when written by a different core, because
            // a memory snapshot cannot be loaded by an emulator that did not
            // make it. Saves survive a core change, so they are never greyed.
            ForEach(states) { state in
                choiceRow(
                    label: state.fileName,
                    detail: state.emulator.map { "state, \($0)" } ?? "state",
                    selected: selectedState?.id == state.id,
                    enabled: state.emulator == nil || state.emulator == selectedCore
                ) {
                    selectedState = selectedState?.id == state.id ? nil : state
                    selectedSave = nil
                }
            }
            ForEach(saves) { save in
                choiceRow(
                    label: save.fileName,
                    detail: "save",
                    selected: selectedSave?.id == save.id,
                    enabled: true
                ) {
                    selectedSave = selectedSave?.id == save.id ? nil : save
                    selectedState = nil
                }
            }
        }
    }

    private func choiceRow(
        label: String, detail: String, selected: Bool, enabled: Bool, tap: @escaping () -> Void
    ) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: Data

    private var launchChoices: LaunchChoices {
        LaunchChoices(
            core: selectedCore,
            firmwareId: selectedFirmware?.id,
            saveId: selectedSave?.id,
            stateId: selectedState?.id,
            useRommScreen: useRommScreen
        )
    }

    private func load() async {
        cores = CoreCatalog.cores(for: rom.platformSlug)
        selectedCore = LaunchChoices.defaultCore(rom: rom, from: cores)

        async let firmwareTask = try? session.firmware(platformId: rom.platformId)
        async let savesTask = try? session.saves(romId: rom.id)
        async let statesTask = try? session.states(romId: rom.id)

        firmware = (await firmwareTask ?? []).filter { !$0.missingFromFS }
        saves = await savesTask ?? []
        states = (await statesTask ?? []).sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }

        // Deliberately no BIOS by default. Every arcade game shares one
        // platform, so "first verified firmware" meant forcing neogeo.zip
        // onto Cave and Capcom boards that have nothing to do with Neo Geo,
        // and a wrong BIOS stops a game booting entirely. RomM only supplies
        // one when the core asks for it, so absent unless chosen is the
        // honest default.
        selectedFirmware = nil
        loading = false
    }
}

/// A grouped card, so the screen reads like Settings rather than a web form.
private struct LaunchCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }
}
