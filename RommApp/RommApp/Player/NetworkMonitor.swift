import Network

/// A cheap, always-current answer to "is there a network path right now",
/// backed by a continuously running `NWPathMonitor` rather than a live
/// probe.
///
/// Exists for the boot watchdog: waiting on an actual request to fail is
/// too slow for a decision that has to happen the moment a boot looks
/// stalled, and the watchdog needs to tell "no signal" apart from "the
/// core cache is corrupted" before it spends its one repair attempt on
/// storage that was never the problem.
actor NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private(set) var isConnected = true

    private init() {
        let queue = DispatchQueue(label: "com.mmagtech.RommApp.networkMonitor")
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { await self?.update(connected) }
        }
        monitor.start(queue: queue)
    }

    private func update(_ connected: Bool) {
        isConnected = connected
    }
}
