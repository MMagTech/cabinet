import SwiftUI
import UIKit

/// Diagnostics for reporting a problem, split out of Settings on purpose:
/// this is read-only information about what the emulator did last, not a
/// setting anyone tunes, and it was confusing sitting in the same list as
/// things people actually configure.
///
/// None of this touches the actual player: `PlayerView`'s webview is the
/// only performance sensitive path in the app, and nothing here reads
/// from or writes to it. `EmulationInfo`, `DiagnosticsLog` and
/// `BridgeConsoleLog` are all plain `UserDefaults` writes made at
/// Settings screens or download/cache completion points, never during
/// gameplay.
struct DebugView: View {
    @EnvironmentObject private var session: Session
    @State private var copied = false
    @StateObject private var repairBridge = EmulatorCacheBridge()
    @State private var showingRepairBridge = false
    @State private var repairing = false
    @State private var repaired = false
    /// Read once for the diagnostics text only. The artwork cache is
    /// deliberately not a setting: it manages its own size, re-downloads
    /// anything it drops, and clearing it fixes nothing, so there is
    /// nothing here for anyone to act on. The number is still worth
    /// carrying in a bug report.
    @State private var artworkBytes: Int64 = 0
    // TODO: this repo is not final. Update once the real one is settled,
    // this one is just where development has lived so far.
    private static let repo = "MMagTech/romm-ios"

    var body: some View {
        List {
            Section {
                Text(EmulationInfo.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if EmulationInfo.recoveries > 0 {
                    LabeledContent("Player reloads survived", value: "\(EmulationInfo.recoveries)")
                }
                if let vitals = EmulationInfo.vitalsAtDeath {
                    Text("Last reload happened at: \(vitals)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Emulation")
            } footer: {
                Text("Recorded from the last game you played.")
            }

            Section {
                LabeledContent("App", value: Self.appVersion)
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("Device", value: Self.deviceModel)
                LabeledContent("Free storage", value: Self.freeStorage)
            } header: {
                Text("Device")
            }

            Section {
                LabeledContent("Server", value: session.serverURL?.host ?? "unknown")
                if let version = session.serverVersion {
                    LabeledContent("RomM version", value: version)
                }
                if !session.scopes.isEmpty {
                    LabeledContent("Pairing scopes", value: session.scopes.joined(separator: ", "))
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Most connection problems trace back to a pairing that's missing a scope.")
            }

            if !DiagnosticsLog.recent.isEmpty {
                Section {
                    ForEach(DiagnosticsLog.recent) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.context): \(entry.message)")
                                .font(.caption)
                            Text(entry.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Clear", role: .destructive) { DiagnosticsLog.clear() }
                } header: {
                    Text("Recent errors")
                } footer: {
                    Text("The last few things that didn't work, wherever in the app they happened.")
                }
            }

            if !BridgeConsoleLog.recent.isEmpty {
                Section {
                    Button("Clear", role: .destructive) { BridgeConsoleLog.clear() }
                } header: {
                    Text("Cache bridge log")
                } footer: {
                    Text("\(BridgeConsoleLog.recent.count) lines from the last Cache or Data Saver use, included in Copy diagnostics.")
                }
            }

            if !PlayerNetworkLog.recent.isEmpty {
                Section {
                    Button("Clear", role: .destructive) { PlayerNetworkLog.clear() }
                } header: {
                    Text("Player network log")
                } footer: {
                    Text("Every request the last game's player made, included in Copy diagnostics. A cached game shows one HEAD line for its /content/ URL; a GET after it means the cache missed. Debug build only.")
                }
            }

            Section {
                Button {
                    showingRepairBridge = true
                    repairing = true
                } label: {
                    if repairing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Repairing")
                        }
                    } else {
                        Label(
                            repaired ? "Player storage repaired" : "Repair player storage",
                            systemImage: repaired ? "checkmark" : "wrench.adjustable"
                        )
                    }
                }
                .disabled(repairing || repaired)
            } footer: {
                Text("If games hang on the loading screen, the player's core cache may be damaged, which can happen when iOS kills the app mid game. This deletes it so cores re-download fresh. Saves, states and cached games aren't touched.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = diagnosticsText
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
                }

                Link(destination: reportURL) {
                    Label("Report a bug", systemImage: "ladybug")
                }
            } footer: {
                Text("Report a bug opens a pre-filled GitHub issue draft, it doesn't post anything until you review and submit it there yourself.")
            }
        }
        .background {
            if showingRepairBridge, let serverURL = session.serverURL {
                EmulatorCacheWebView(url: serverURL, bridge: repairBridge)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: repairBridge.isReady) { _, ready in
            guard ready else { return }
            Task {
                await repairBridge.repairPlayerStorage()
                repairing = false
                repaired = true
            }
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        .task { artworkBytes = await CoverCache.shared.diskUsage() }
    }

    private var diagnosticsText: String {
        var lines = [
            "Cabinet \(Self.appVersion), iOS \(UIDevice.current.systemVersion), \(Self.deviceModel)",
            "Free storage: \(Self.freeStorage)",
            "Artwork cache: \(ByteCountFormatter.string(fromByteCount: artworkBytes, countStyle: .file))",
            "RomM \(session.serverVersion ?? "unknown") at \(session.serverURL?.host ?? "unknown")",
            "Pairing scopes: \(session.scopes.isEmpty ? "none" : session.scopes.joined(separator: ", "))",
            EmulationInfo.summary,
            "Player reloads survived: \(EmulationInfo.recoveries)",
        ]
        if let vitals = EmulationInfo.vitalsAtDeath {
            lines.append("Last reload: \(vitals)")
        }
        let recentErrors = DiagnosticsLog.recent
        if !recentErrors.isEmpty {
            lines.append("")
            lines.append("Recent errors:")
            lines.append(
                contentsOf: recentErrors.map { "- [\($0.context)] \($0.message) (RomM \($0.romVersion ?? "?"))" }
            )
        }
        let bridgeLog = BridgeConsoleLog.recent
        if !bridgeLog.isEmpty {
            lines.append("")
            lines.append("Cache bridge log:")
            lines.append(contentsOf: bridgeLog)
        }
        let playerLog = PlayerNetworkLog.recent
        if !playerLog.isEmpty {
            lines.append("")
            lines.append("Player network log:")
            lines.append(contentsOf: playerLog)
        }
        return "```\n" + lines.joined(separator: "\n") + "\n```"
    }

    private var reportURL: URL {
        var components = URLComponents(string: "https://github.com/\(Self.repo)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "Bug report"),
            URLQueryItem(name: "body", value: diagnosticsText + "\n\nWhat happened:\n"),
        ]
        return components.url!
    }

    private static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }

    private static var freeStorage: String {
        guard
            let values = try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
