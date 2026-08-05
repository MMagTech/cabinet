import SwiftUI

/// The one screen the app shows when it cannot reach the server.
///
/// Deliberately the same everywhere (Home, the library, a game list)
/// rather than three differently worded errors, because it is one
/// situation with one answer. Before this existed, no signal meant a
/// spinner that ran for the full request timeout and then either a raw
/// `localizedDescription` or, on Home, an empty state implying you owned
/// no games at all.
///
/// There is nothing to browse offline on purpose: the library lives on
/// the server and this app deliberately keeps no snapshot of it, so the
/// honest answer is to say so and offer a retry rather than to imply
/// some of the app still works.
struct OfflineNotice: View {
    var retry: () async -> Void

    @State private var retrying = false

    var body: some View {
        ContentUnavailableView {
            Label("No connection to your server", systemImage: "wifi.slash")
        } description: {
            Text("Check your signal, then try again.")
        } actions: {
            Button {
                Task {
                    retrying = true
                    await retry()
                    retrying = false
                }
            } label: {
                if retrying {
                    ProgressView()
                } else {
                    Text("Try again")
                }
            }
            .disabled(retrying)
        }
    }
}

/// A failure that is worth telling the person about, split by whether they
/// can do anything about it. Views hold one of these instead of a bare
/// `String` so the offline case can get its own treatment without every
/// screen re-testing the error itself.
enum LoadFailure: Equatable {
    case offline
    case other(String)

    init(_ error: Error) {
        if case RommError.offline = error {
            self = .offline
        } else {
            self = .other(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .offline: return "No connection to your server."
        case .other(let message): return message
        }
    }
}
