//  Download All, for a platform, on the Mac.
//
//  A phone keeps a handful of games. A desk machine has the disk for a
//  whole system, so the Mac offers one action per platform, in the
//  places a Mac puts an action on a source: the sidebar row's context
//  menu and the Library tile's. It keeps every game the store can keep,
//  playable here or not, since a file for another emulator is still a
//  file worth having; that is the same rule a single download follows.
//
//  Apple's shape for a large download: say the count and the size
//  before starting, refuse plainly when the disk cannot hold it, then
//  run without ceremony and show progress where it was started. The
//  confirmation is an alert with a message, the Mac's confirmation; the
//  progress is the menu item itself, "Downloading 12 of 66…", with
//  Cancel beneath it. No new screen.

import Combine
import SwiftUI
import UserNotifications

/// One prompt for the whole app, attached once to the shell, driven by
/// either menu. Fetches the platform's full list, sizes it, checks the
/// disk, and hands the list to the store's queue on confirmation.
@MainActor
final class MacDownloadAll: ObservableObject {
    static let shared = MacDownloadAll()

    /// `name` is the label the menu showed, the sidebar's own, never
    /// built here: a platform's name fields come from RomM as optionals
    /// and the first build printed one wrapped as Optional("…").
    enum Prompt: Identifiable {
        case confirm(platform: Platform, name: String, roms: [Rom], bytes: Int64, free: Int64?)
        case nothing(name: String)
        case noSpace(name: String, bytes: Int64, free: Int64)
        case failed(message: String)
        case removeAll(platform: Platform, name: String, count: Int)

        var id: String {
            switch self {
            case .confirm(let p, _, _, _, _): return "confirm.\(p.id)"
            case .removeAll(let p, _, _): return "remove.\(p.id)"
            case .nothing(let n): return "nothing.\(n)"
            case .noSpace(let n, _, _): return "nospace.\(n)"
            case .failed(let m): return "failed.\(m)"
            }
        }
    }

    @Published var prompt: Prompt?
    @Published private(set) var preparing: Int?
    /// The label of the platform whose queue is running, for the
    /// sidebar's status line and the notification.
    @Published private(set) var runningLabel: String?

    private var watcher: AnyCancellable?
    private var lastBulk: KeptGameStore.BulkDownload?

    private init() {
        // Watches the store's queue end. Apple's guidance: a notification
        // shows only when the app is not in front, and in front the
        // result is shown "in a way that's discoverable but not
        // distracting", which here is the sidebar status ending and the
        // Downloaded count. So the banner goes out only in the
        // background, one per queue, and never for an error, which the
        // page says belongs in an alert, not a notification.
        watcher = KeptGameStore.shared.$bulk.sink { [weak self] bulk in
            guard let self else { return }
            if let bulk {
                self.lastBulk = bulk
                return
            }
            guard let finished = self.lastBulk else { return }
            self.lastBulk = nil
            let label = self.runningLabel ?? "Platform"
            self.runningLabel = nil
            guard UIApplication.shared.applicationState != .active else { return }
            let kept = finished.done - finished.failed
            let content = UNMutableNotificationContent()
            content.title = "\(label) downloaded"
            content.body = finished.failed == 0
                ? "\(kept) games"
                : "\(kept) games. \(finished.failed) didn't finish."
            let request = UNNotificationRequest(identifier: "downloadall.\(finished.platformId)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Starts the queue for a confirmed platform, asking for notification
    /// permission at this moment rather than at launch: the first Download
    /// All is the first time the app has a reason to ask.
    func start(platform: Platform, name: String, roms: [Rom], session: Session) {
        runningLabel = name
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        KeptGameStore.shared.keepAll(roms, platformId: platform.id, session: session)
    }

    /// Everything on the platform the store can keep and does not have.
    func prepare(_ platform: Platform, name: String, session: Session) {
        guard preparing == nil else { return }
        preparing = platform.id
        Task {
            defer { preparing = nil }
            do {
                var all: [Rom] = []
                var total = Int.max
                while all.count < total {
                    let page = try await session.roms(platformId: platform.id, limit: 200, offset: all.count)
                    total = page.total
                    if page.items.isEmpty { break }
                    all.append(contentsOf: page.items)
                }
                let store = KeptGameStore.shared
                let wanted = all.filter { rom in
                    store.kept(romId: rom.id) == nil
                        && KeptGameStore.isKeepable(rom, canonicalSlug: rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions))
                }
                guard !wanted.isEmpty else {
                    prompt = .nothing(name: name)
                    return
                }
                let bytes = wanted.reduce(Int64(0)) { $0 + $1.fsSizeBytes }
                let free = store.availableCapacity()
                if let free, free < bytes {
                    prompt = .noSpace(name: name, bytes: bytes, free: free)
                } else {
                    prompt = .confirm(platform: platform, name: name, roms: wanted, bytes: bytes, free: free)
                }
            } catch {
                prompt = .failed(message: error.localizedDescription)
            }
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A platform's context menu on the Mac: Download All, Remove All
/// Downloads, Show in Finder, on the sidebar row and the Library tile,
/// and without Download All in Downloaded. One vocabulary for a
/// platform wherever it is met. (A menu drawn twice over itself was
/// chased through this file's item count for an evening; it was
/// MacWindow's title bar poll, since removed, and the count is free.)
struct MacPlatformMenu: View {
    let platform: Platform
    let label: String
    /// Off in Downloaded, where a platform is what is already on disk
    /// and an offer to download it reads as nonsense.
    var offersDownloadAll = true
    @EnvironmentObject private var session: Session
    @ObservedObject private var store = KeptGameStore.shared
    @ObservedObject private var prompt = MacDownloadAll.shared

    private var keptCount: Int {
        store.games.filter { $0.rom.platformId == platform.id }.count
    }

    var body: some View {
        if let bulk = store.bulk, bulk.platformId == platform.id {
            Button("Downloading \\(min(bulk.done + 1, bulk.total)) of \\(bulk.total)…") {}
                .disabled(true)
            Button("Cancel Download") { store.cancelBulk() }
        } else {
            if offersDownloadAll {
                Button {
                    prompt.prepare(platform, name: label, session: session)
                } label: {
                    Label("Download All…", systemImage: "arrow.down.circle")
                }
                .disabled(store.bulk != nil || prompt.preparing == platform.id)
            }
            Button(role: .destructive) {
                prompt.prompt = .removeAll(platform: platform, name: label, count: keptCount)
            } label: {
                Label("Remove All Downloads…", systemImage: "trash")
            }
            .disabled(keptCount == 0 || store.bulk != nil)
        }
        Button {
            if let folder = store.mirrorRomsFolder(platformFsSlug: platform.fsSlug) {
                UIApplication.shared.open(folder)
            }
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .disabled(store.mirrorRomsFolder(platformFsSlug: platform.fsSlug) == nil)
    }
}

/// The confirmation, attached once to the shell.
struct MacDownloadAllPrompt: ViewModifier {
    @EnvironmentObject private var session: Session
    @ObservedObject private var prompt = MacDownloadAll.shared

    func body(content: Content) -> some View {
        content
        .onReceive(NotificationCenter.default.publisher(for: .cabinetDownloadAllSelected)) { _ in
            guard let selected = MacChrome.shared.selectedPlatform else { return }
            prompt.prepare(selected.platform, name: selected.label, session: session)
        }
        .alert(item: $prompt.prompt) { item in
            switch item {
            case .confirm(let platform, let name, let roms, let bytes, let free):
                var message = "\(roms.count) games, about \(MacDownloadAll.size(bytes))."
                if let free { message += " \(MacDownloadAll.size(free)) free." }
                // Two lines: the action, then the system on its own
                // line, so a long platform name does not wrap the
                // question mid-phrase (Marcus, 2026-09-02).
                return Alert(
                    title: Text("Download All\n\(name)?"),
                    message: Text(message),
                    primaryButton: .default(Text("Download")) {
                        MacDownloadAll.shared.start(platform: platform, name: name, roms: roms, session: session)
                    },
                    secondaryButton: .cancel()
                )
            case .nothing(let name):
                return Alert(
                    title: Text("Nothing to download"),
                    message: Text("Every game on \(name) that can be kept is already on this Mac."),
                    dismissButton: .default(Text("OK"))
                )
            case .noSpace(let name, let bytes, let free):
                return Alert(
                    title: Text("Not enough space"),
                    message: Text("\(name) needs about \(MacDownloadAll.size(bytes)) and this Mac has \(MacDownloadAll.size(free)) free."),
                    dismissButton: .default(Text("OK"))
                )
            case .failed(let message):
                return Alert(
                    title: Text("Couldn't read the platform"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            case .removeAll(let platform, let name, let count):
                return Alert(
                    title: Text("Remove All Downloads\n\(name)?"),
                    message: Text("\(count) games come off this Mac. Save states already sent to RomM stay there."),
                    primaryButton: .destructive(Text("Remove")) {
                        KeptGameStore.shared.removeAll(platformId: platform.id)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }
}

extension View {
    func macDownloadAllPrompt() -> some View { modifier(MacDownloadAllPrompt()) }
}

/// The sidebar's status line while a platform downloads, at its foot,
/// the way Photos reports its own uploads and downloads there: the
/// platform, the count, a thin bar, and a cancel. Visible from every
/// screen, interrupting none, and gone when the queue is.
struct MacDownloadAllStatus: View {
    @ObservedObject private var store = KeptGameStore.shared
    @ObservedObject private var prompt = MacDownloadAll.shared

    var body: some View {
        if let bulk = store.bulk {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloading \(prompt.runningLabel ?? "")")
                            .font(.callout)
                            .lineLimit(1)
                        Text("\(min(bulk.done + 1, bulk.total)) of \(bulk.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button {
                        store.cancelBulk()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel Download")
                }
                ProgressView(value: Double(bulk.done), total: Double(max(bulk.total, 1)))
                    .progressViewStyle(.linear)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }
}
