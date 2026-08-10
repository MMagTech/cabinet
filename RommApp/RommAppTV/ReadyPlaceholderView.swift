#if os(tvOS)
import SwiftUI

/// Stands in for `MainTabView` until Home/Library/Player are ported. Real
/// gameplay needs native cores rebuilt for tvOS first, that's the next step
/// after this target boots and pairs.
struct ReadyPlaceholderView: View {
    @EnvironmentObject private var session: Session
    @State private var showingPerfTest = false
    @State private var showingPlayTest = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Paired")
                .font(.title.bold())
            if let host = session.serverURL?.host {
                Text(host)
                    .foregroundStyle(.secondary)
            }
            Button("Run PS1 performance test") { showingPerfTest = true }
                .padding(.top, 24)
            Button("Play PS1 test (controller required)") { showingPlayTest = true }
            Button("Use a different server") { session.forgetServer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fullScreenCover(isPresented: $showingPerfTest) {
            PS1PerfTestView()
        }
        .fullScreenCover(isPresented: $showingPlayTest) {
            PS1PlayTestView()
        }
    }
}
#endif
