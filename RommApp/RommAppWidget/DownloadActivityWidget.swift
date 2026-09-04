import ActivityKit
import SwiftUI
import WidgetKit

/// Download All, while it runs, in the places iOS shows live progress:
/// the Dynamic Island and the Lock Screen. Apple's page for Live
/// Activities: an app must support every presentation and the system
/// picks one per place, so this draws all four, compact and minimal
/// as an icon and a count, expanded and Lock Screen as the platform, the
/// count and a bar. The app updates it as games land and ends it with
/// the final count, which lingers on the Lock Screen for a while.
struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadActivityLockScreen(name: context.attributes.platformName, state: context.state)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.platformName, systemImage: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.headline)
                        .lineLimit(1)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(DownloadActivityText.count(state))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: Double(state.done), total: Double(max(state.total, 1)))
                        .tint(state.finished ? .green : .accentColor)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(state.finished ? .green : .accentColor)
            } compactTrailing: {
                Text(DownloadActivityText.compact(state))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(state.finished ? .green : .accentColor)
            }
        }
    }
}

struct DownloadActivityLockScreen: View {
    let name: String
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(state.finished ? .green : .accentColor)
                Text(DownloadActivityText.title(name, state))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(DownloadActivityText.count(state))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(state.done), total: Double(max(state.total, 1)))
                .tint(state.finished ? .green : .accentColor)
            if state.finished, state.failed > 0 {
                Text("\(state.failed) didn't finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum DownloadActivityText {
    /// A queue that ended short of its total was cancelled; it says so
    /// rather than claiming the platform downloaded.
    static func stopped(_ state: DownloadActivityAttributes.ContentState) -> Bool {
        state.finished && state.done < state.total
    }

    static func title(_ name: String, _ state: DownloadActivityAttributes.ContentState) -> String {
        if !state.finished { return "Downloading \(name)" }
        return stopped(state) ? "\(name) stopped" : "\(name) downloaded"
    }

    /// "12 of 66" while running, "66 games" when done, the notification's
    /// own wording; "12 of 66" again when stopped.
    static func count(_ state: DownloadActivityAttributes.ContentState) -> String {
        if !state.finished { return "\(min(state.done + 1, state.total)) of \(state.total)" }
        return stopped(state) ? "\(state.done - state.failed) of \(state.total)" : "\(state.done - state.failed) games"
    }

    static func compact(_ state: DownloadActivityAttributes.ContentState) -> String {
        state.finished ? "Done" : "\(min(state.done + 1, state.total))/\(state.total)"
    }
}
