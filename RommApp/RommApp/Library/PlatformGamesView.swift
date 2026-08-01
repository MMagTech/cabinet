import SwiftUI

/// The games of one platform, as a cover grid or a compact text list.
///
/// The mode preference persists per platform slug, because arcade sets often
/// have no cover art and a grid of gray tiles is worse than a text list, while
/// console libraries look far better as covers. One preference for both would
/// force a bad default on one of them.
struct PlatformGamesView: View {
    let platform: Platform

    @EnvironmentObject private var session: Session
    @State private var roms: [Rom] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var viewMode: ViewMode

    enum ViewMode: String {
        case grid, list
    }

    init(platform: Platform) {
        self.platform = platform
        let stored = UserDefaults.standard.string(forKey: Self.modeKey(for: platform.slug))
        _viewMode = State(initialValue: stored.flatMap(ViewMode.init) ?? .grid)
    }

    private static func modeKey(for slug: String) -> String {
        "com.mmagtech.RommApp.viewMode.\(slug)"
    }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("Could not load games", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await reload() } }
                }
            } else {
                switch viewMode {
                case .grid: grid
                case .list: list
                }
            }
        }
        .navigationTitle(platform.name ?? platform.slug)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("View", selection: $viewMode) {
                    Image(systemName: "square.grid.3x3").tag(ViewMode.grid)
                    Image(systemName: "list.bullet").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
            }
        }
        .onChange(of: viewMode) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey(for: platform.slug))
        }
        .task { await reload() }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 12)],
                spacing: 12
            ) {
                ForEach(roms) { rom in
                    VStack(spacing: 6) {
                        CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                            .aspectRatio(3.0 / 4.0, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 10))

                        Text(rom.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { Task { await loadMoreIfNeeded(current: rom) } }
                }
            }
            .padding(.horizontal, 16)

            footer
        }
    }

    private var list: some View {
        List {
            ForEach(roms) { rom in
                Text(rom.displayName)
                    .lineLimit(1)
                    .onAppear { Task { await loadMoreIfNeeded(current: rom) } }
            }

            footer
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var footer: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        } else if !roms.isEmpty {
            Text("\(roms.count) of \(total)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    private func reload() async {
        roms = []
        total = 0
        error = nil
        await loadNextPage()
    }

    private func loadMoreIfNeeded(current rom: Rom) async {
        guard rom.id == roms.last?.id, roms.count < total else { return }
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !loading else { return }
        loading = true
        do {
            let page = try await session.roms(platformId: platform.id, offset: roms.count)
            roms.append(contentsOf: page.items)
            total = page.total
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
