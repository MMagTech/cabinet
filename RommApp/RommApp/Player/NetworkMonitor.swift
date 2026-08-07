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

    private let monitor = NWPathMonitor()
    @Published private(set) var isConnected = true

    private init() {
        let queue = DispatchQueue(label: "com.mmagtech.RommApp.networkMonitor")
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in self?.isConnected = connected }
        }
        monitor.start(queue: queue)
    }
}
