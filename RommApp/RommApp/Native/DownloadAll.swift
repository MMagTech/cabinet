//  Download All, for a platform.
//
//  A phone keeps a handful of games and a desk machine has the disk for
//  a whole system, but the action is the same on both: one Download All
//  per platform, in the places each platform puts an action on a source.
//  It keeps every game the store can keep, playable here or not, since a
//  file for another emulator is still a file worth having; that is the
//  same rule a single download follows.
//
//  Apple's shape for a large download: say the count and the size before
//  starting, refuse plainly when the disk cannot hold it, then run
//  without ceremony and show progress where it was started. The
//  confirmation is an alert with a message; the progress is the menu
//  item itself, "Downloading 12 of 66…", with Cancel beneath it, and a
//  status line where each platform keeps one. No new screen.
//
//  Built for the Mac on 2026-09-02 and moved here for the phone the next
//  day. The phone's transfers run in the system's background session
//  (BackgroundDownloads) and over Wi-Fi only, so a queue started at the
//  kitchen table finishes with the phone locked in a pocket; the queue
//  itself is written down, so a launch after the system has quit the app
//  picks it up where it stopped. The Mac downloads in the foreground and
//  needs neither.

#if !os(tvOS)
import Combine
import SwiftUI
import UserNotifications
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// One prompt for the whole app, attached once to the shell, driven by
/// any of the menus. Fetches the platform's full list, sizes it, checks
/// the disk, and hands the list to the store's queue on confirmation.
@MainActor
final class DownloadAll: ObservableObject {
    static let shared = DownloadAll()

    /// `name` is the label the menu showed, never built here: a
    /// platform's name fields come from RomM as optionals and the first
    /// build printed one wrapped as Optional("…").
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
    /// The label of the platform whose queue is running, for the status
    /// line and the notification.
    @Published private(set) var runningLabel: String?

    private var watcher: AnyCancellable?
    private var networkWatcher: AnyCancellable?
    private var lastBulk: KeptGameStore.BulkDownload?

    private init() {
        // Watches the store's queue end. Apple's guidance: a notification
        // shows only when the app is not in front, and in front the
        // result is shown "in a way that's discoverable but not
        // distracting", which here is the status line ending and the
        // Downloaded count. So the banner goes out only in the
        // background, one per queue, and never for an error, which the
        // page says belongs in an alert, not a notification.
        watcher = KeptGameStore.shared.$bulk.sink { [weak self] bulk in
            guard let self else { return }
            if let bulk {
                self.lastBulk = bulk
                #if os(iOS) && !targetEnvironment(macCatalyst)
                DownloadLiveActivity.shared.update(done: bulk.done, total: bulk.total, failed: bulk.failed)
                #endif
                return
            }
            guard let finished = self.lastBulk else { return }
            self.lastBulk = nil
            #if os(iOS) && !targetEnvironment(macCatalyst)
            DownloadLiveActivity.shared.end(done: finished.done, total: finished.total, failed: finished.failed)
            #endif
            #if os(iOS) && !targetEnvironment(macCatalyst)
            Self.clearRecord()
            #endif
            let label = self.runningLabel ?? "Platform"
            self.runningLabel = nil
            guard UIApplication.shared.applicationState != .active else { return }
            let kept = finished.done - finished.failed
            let content = UNMutableNotificationContent()
            let stopped = finished.done < finished.total
            content.title = stopped ? "\(label) stopped" : "\(label) downloaded"
            content.body = stopped
                ? "\(kept) of \(finished.total) games"
                : finished.failed == 0 ? "\(kept) games" : "\(kept) games. \(finished.failed) didn't finish."
            let request = UNNotificationRequest(identifier: "downloadall.\(finished.platformId)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // Wi-Fi coming or going flips the activity between Downloading
        // and Waiting for Wi-Fi without waiting for the next game.
        networkWatcher = NetworkMonitor.shared.$isExpensive
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let bulk = self?.lastBulk else { return }
                DownloadLiveActivity.shared.update(done: bulk.done, total: bulk.total, failed: bulk.failed)
            }
        #endif
    }

    /// Starts the queue for a confirmed platform, asking for notification
    /// permission at this moment rather than at launch: the first Download
    /// All is the first time the app has a reason to ask.
    func start(platform: Platform, name: String, roms: [Rom], session: Session) {
        runningLabel = name
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        Self.writeRecord(Record(platformId: platform.id, name: name, roms: roms))
        #endif
        KeptGameStore.shared.keepAll(roms, platformId: platform.id, session: session)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if let bulk = KeptGameStore.shared.bulk {
            DownloadLiveActivity.shared.start(platformName: name, total: bulk.total)
        }
        #endif
    }

    /// Everything on the platform the store can keep and does not have.
    func prepare(_ platform: Platform, name: String, session: Session) {
        guard preparing == nil else { return }
        preparing = platform.id
        Task {
            defer { preparing = nil }
            do {
                // A no-op once the mapping is in hand; without it a
                // platform whose folder name is not its slug would size
                // as though nothing on it could be kept.
                await session.loadPlatformConfigIfNeeded()
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

    /// Whether the phone's queue is parked on cellular. Only the phone
    /// refuses cellular; the Mac downloads over whatever it has.
    static var waitingForWiFi: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return NetworkMonitor.shared.isExpensive
        #else
        return false
        #endif
    }

    /// "this Mac", "this iPhone", "this iPad", for the alerts.
    static var deviceWord: String {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #else
        return UIDevice.current.model
        #endif
    }

    // MARK: The queue across launches, phone only

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// What was confirmed, written when the queue starts and removed
    /// when it ends, so a launch after the system quit the app mid-queue
    /// can carry on. Transfers already handed to the background session
    /// are found again by BackgroundDownloads; this is the list that
    /// says what to finish once they land.
    private struct Record: Codable {
        let platformId: Int
        let name: String
        let roms: [Rom]
    }

    private static var recordURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("download-all.json")
    }

    private static func writeRecord(_ record: Record) {
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: recordURL, options: .atomic)
        }
    }

    private static func clearRecord() {
        try? FileManager.default.removeItem(at: recordURL)
    }

    /// Picks up a queue a previous launch left unfinished. Called when
    /// the shell appears with a session; nothing to do on every launch
    /// that did not stop mid-queue, which is nearly all of them.
    func resumeIfNeeded(session: Session) {
        guard KeptGameStore.shared.bulk == nil,
              let data = try? Data(contentsOf: Self.recordURL),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return }
        let remaining = record.roms.filter { KeptGameStore.shared.kept(romId: $0.id) == nil }
        guard !remaining.isEmpty else {
            Self.clearRecord()
            return
        }
        runningLabel = record.name
        DownloadLiveActivity.shared.adopt()
        KeptGameStore.shared.keepAll(remaining, platformId: record.platformId, session: session)
    }
    #endif

    // MARK: Harness

    #if DEBUG
    /// Proves the queue without a hand on the screen: waits for a
    /// session, fetches the platform, starts the queue, cancels it after
    /// N seconds if asked, and logs each step. `-cabinetDownloadAll
    /// <platformId> -cabinetDownloadAllCancelAt <seconds>`, and
    /// `-cabinetDownloadAllStay 1` to leave the app running afterwards,
    /// for watching the phone's queue survive the background.
    static func runHarnessIfRequested(session: Session) async {
        let platformId = UserDefaults.standard.integer(forKey: "cabinetDownloadAll")
        guard platformId > 0 else { return }
        let store = KeptGameStore.shared
        while session.stage != .ready { try? await Task.sleep(for: .seconds(1)) }
        await session.loadPlatformConfigIfNeeded()
        let platform = Platform(id: platformId, name: "bench", displayName: nil, slug: "bench", fsSlug: "bench", romCount: 0)
        shared.prepare(platform, name: "bench", session: session)
        while shared.preparing != nil { try? await Task.sleep(for: .milliseconds(200)) }
        guard case .confirm(_, _, let roms, let bytes, let free) = shared.prompt else {
            NSLog("[downloadall] prompt: %@", String(describing: shared.prompt)); return
        }
        NSLog("[downloadall] %d games, %lld bytes, free %lld", roms.count, bytes, free ?? -1)
        shared.prompt = nil
        shared.start(platform: platform, name: "bench", roms: roms, session: session)
        let cancelAt = UserDefaults.standard.integer(forKey: "cabinetDownloadAllCancelAt")
        var tick = 0
        while let bulk = store.bulk {
            NSLog("[downloadall] t=%ds done=%d of %d current=%d failed=%d", tick, bulk.done, bulk.total, bulk.currentRomId ?? -1, bulk.failed)
            if cancelAt > 0, tick == cancelAt { NSLog("[downloadall] cancelling"); store.cancelBulk() }
            try? await Task.sleep(for: .seconds(1)); tick += 1
        }
        NSLog("[downloadall] finished, kept=%d", store.games.count)
        guard !UserDefaults.standard.bool(forKey: "cabinetDownloadAllStay") else { return }
        try? await Task.sleep(for: .seconds(1))
        exit(0)
    }
    #endif
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// The queue in the Dynamic Island and on the Lock Screen, the phone's
/// native place for progress while the app is not in front (Marcus,
/// 2026-09-03). One activity for the one queue the app runs at a time.
/// Updates go out at most once a second: Apple budgets how often an
/// activity may change, and a queue lands several games a second on a
/// fast network, so the counter ticks rather than flickers. Ended with
/// the final count and left on the Lock Screen a while, per Apple's
/// guidance to always end an activity with its final content and a
/// dismissal policy; the eight hour ceiling is far past any queue here.
@MainActor
final class DownloadLiveActivity {
    static let shared = DownloadLiveActivity()

    private var activity: Activity<DownloadActivityAttributes>?
    private var pending: DownloadActivityAttributes.ContentState?
    private var flush: Task<Void, Never>?

    private init() {}

    func start(platformName: String, total: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // A leftover from a queue that ended while the app was gone.
        for stale in Activity<DownloadActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        let attributes = DownloadActivityAttributes(platformName: platformName)
        let state = DownloadActivityAttributes.ContentState(
            done: 0, total: total, failed: 0, finished: false, waitingForWiFi: DownloadAll.waitingForWiFi
        )
        activity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    /// After a relaunch, the activity a previous launch started.
    func adopt() {
        activity = Activity<DownloadActivityAttributes>.activities.first
    }

    func update(done: Int, total: Int, failed: Int) {
        guard activity != nil else { return }
        pending = .init(done: done, total: total, failed: failed, finished: false, waitingForWiFi: DownloadAll.waitingForWiFi)
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.flush = nil
            guard let state = self.pending, let activity = self.activity else { return }
            self.pending = nil
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    func end(done: Int, total: Int, failed: Int) {
        flush?.cancel()
        flush = nil
        pending = nil
        guard let activity else { return }
        self.activity = nil
        let state = DownloadActivityAttributes.ContentState(done: done, total: total, failed: failed, finished: true, waitingForWiFi: false)
        Task {
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date(timeIntervalSinceNow: 15 * 60)))
        }
    }
}
#endif

/// What a platform's menu offers about downloads, wherever a platform is
/// met: Download All and Remove All Downloads, or while its queue runs,
/// the count and a Cancel. The Mac adds Show in Finder after these.
struct PlatformDownloadMenuItems: View {
    let platform: Platform
    let label: String
    /// Off in Downloaded, where a platform is what is already on disk
    /// and an offer to download it reads as nonsense.
    var offersDownloadAll = true
    @EnvironmentObject private var session: Session
    @ObservedObject private var store = KeptGameStore.shared
    @ObservedObject private var prompt = DownloadAll.shared
    @ObservedObject private var network = NetworkMonitor.shared

    private var keptCount: Int {
        store.games.filter { $0.rom.platformId == platform.id }.count
    }

    var body: some View {
        if let bulk = store.bulk, bulk.platformId == platform.id {
            Button(DownloadAll.waitingForWiFi
                ? "Waiting for Wi-Fi, \(min(bulk.done + 1, bulk.total)) of \(bulk.total)"
                : "Downloading \(min(bulk.done + 1, bulk.total)) of \(bulk.total)…") {}
                .disabled(true)
            Button("Cancel Download") { store.cancelBulk() }
        } else {
            if offersDownloadAll {
                // Greyed out once every game on the platform is kept,
                // rather than answering with an alert that says so
                // (Marcus, 2026-09-03). The server's count is the
                // cheap test; the alert stays as the fallback for a
                // platform whose remaining games cannot be kept.
                Button {
                    prompt.prepare(platform, name: label, session: session)
                } label: {
                    Label("Download All…", systemImage: "arrow.down.circle")
                }
                .disabled(store.bulk != nil || prompt.preparing == platform.id || (platform.romCount > 0 && keptCount >= platform.romCount))
            }
            Button(role: .destructive) {
                prompt.prompt = .removeAll(platform: platform, name: label, count: keptCount)
            } label: {
                Label("Remove All Downloads…", systemImage: "trash")
            }
            .disabled(keptCount == 0 || store.bulk != nil)
        }
    }
}

/// The confirmation, attached once to each platform's shell.
struct DownloadAllPrompt: ViewModifier {
    @EnvironmentObject private var session: Session
    @ObservedObject private var prompt = DownloadAll.shared

    func body(content: Content) -> some View {
        content.alert(item: $prompt.prompt) { item in
            switch item {
            case .confirm(let platform, let name, let roms, let bytes, let free):
                var message = "\(roms.count) games, about \(DownloadAll.size(bytes))."
                if let free { message += " \(DownloadAll.size(free)) free." }
                #if os(iOS) && !targetEnvironment(macCatalyst)
                // The phone's queue never touches cellular. Said once,
                // here, and as a wait rather than a refusal when the
                // phone is on cellular right now.
                message += NetworkMonitor.shared.isExpensive ? " Waits for Wi-Fi." : " Wi-Fi only."
                #endif
                // Two lines: the action, then the system on its own
                // line, so a long platform name does not wrap the
                // question mid-phrase (Marcus, 2026-09-02).
                return Alert(
                    title: Text("Download All\n\(name)?"),
                    message: Text(message),
                    primaryButton: .default(Text("Download")) {
                        DownloadAll.shared.start(platform: platform, name: name, roms: roms, session: session)
                    },
                    secondaryButton: .cancel()
                )
            case .nothing(let name):
                return Alert(
                    title: Text("Nothing to download"),
                    message: Text("Every game on \(name) that can be kept is already on this \(DownloadAll.deviceWord)."),
                    dismissButton: .default(Text("OK"))
                )
            case .noSpace(let name, let bytes, let free):
                return Alert(
                    title: Text("Not enough space"),
                    message: Text("\(name) needs about \(DownloadAll.size(bytes)) and this \(DownloadAll.deviceWord) has \(DownloadAll.size(free)) free."),
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
                    message: Text("\(count) games come off this \(DownloadAll.deviceWord). Save states already sent to RomM stay there."),
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
    func downloadAllPrompt() -> some View { modifier(DownloadAllPrompt()) }
}

/// The status as a card for the phone, set into the top of Home and of
/// the platform being downloaded, the way Home already floats its sync
/// summary there: visible wherever a person lands, and gone with the
/// queue. The Mac has its sidebar foot for this and does not use it.
struct DownloadAllStatusCard: View {
    @ObservedObject private var store = KeptGameStore.shared

    var body: some View {
        if store.bulk != nil {
            DownloadAllStatusContent()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The status while a platform downloads: the platform, the count, a
/// thin bar, and a cancel. The Mac sets it at the sidebar's foot, the
/// way Photos reports its own transfers there; the phone shows it at
/// the top of Storage. Gone when the queue is.
struct DownloadAllStatusContent: View {
    @ObservedObject private var store = KeptGameStore.shared
    @ObservedObject private var prompt = DownloadAll.shared
    @ObservedObject private var network = NetworkMonitor.shared

    var body: some View {
        if let bulk = store.bulk {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        // On cellular the phone's queue is parked, and a
                        // card that says Downloading over a bar that does
                        // not move reads as broken (Marcus, 2026-09-03).
                        Text(DownloadAll.waitingForWiFi ? "Waiting for Wi-Fi" : "Downloading \(prompt.runningLabel ?? "")")
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
        }
    }
}
#endif
