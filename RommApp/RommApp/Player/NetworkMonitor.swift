import Network
import SwiftUI

/// A cheap, always-current, observable answer to "is there a network path
/// right now", backed by a continuously running `NWPathMonitor`.
///
/// `@MainActor` and `ObservableObject`, not an actor, since the whole point
/// of tonight's follow-up is that screens need to react the instant this
/// changes, not only when they happen to ask. An actor's stored property
/// can only be polled; a `@Published` one can be watched, so Home and the
/// library can update live off airplane mode instead of only noticing on
/// their next manual load, which is what an actor-backed version left them
/// unable to do (Marcus, 2026-08-07: "I have to exit it and then reenter to
/// see offline view").
///
/// Originally built for the boot watchdog alone: waiting on an actual
/// request to fail is too slow for a decision that has to happen the
/// moment a boot looks stalled, and the watchdog needs to tell "no signal"
/// apart from "the core cache is corrupted" before it spends its one
/// repair attempt on storage that was never the problem. That use still
/// works unchanged, a synchronous read instead of an awaited one.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    private static let manualOfflineKey = "com.mmagtech.RommApp.manualOfflineMode"

    private let monitor = NWPathMonitor()
    /// The literal hardware truth: is there a network path right now.
    @Published private(set) var isConnected = true
    /// A person's own choice to have the app act as though there is no
    /// connection, kept games only, even when there genuinely is one.
    /// The Low Data Mode shape, not a fallback for a broken signal: the
    /// same reason to have it exists whether or not signal is actually
    /// weak, roaming, a capped hotspot, or simply not wanting a big
    /// download to fire while there is one. Persisted, so it survives a
    /// relaunch the way a real mode should. Marcus, 2026-08-07.
    @Published var manualOfflineMode: Bool {
        didSet { UserDefaults.standard.set(manualOfflineMode, forKey: Self.manualOfflineKey) }
    }

    /// What every screen actually asks. Real signal loss and the manual
    /// choice both answer this the same way on purpose: one signal, so
    /// every screen already wired to react to it behaves identically
    /// regardless of which caused it, no separate offline system to
    /// maintain for the manual case.
    var isOffline: Bool { !isConnected || manualOfflineMode }

    private init() {
        manualOfflineMode = UserDefaults.standard.bool(forKey: Self.manualOfflineKey)
        let queue = DispatchQueue(label: "com.mmagtech.RommApp.networkMonitor")
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in self?.isConnected = connected }
        }
        monitor.start(queue: queue)
    }
}
