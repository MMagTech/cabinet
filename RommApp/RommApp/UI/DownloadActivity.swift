//  The shape of the Download All Live Activity, shared by the app, which
//  starts and updates it, and the widget extension, which draws it in
//  the Dynamic Island and on the Lock Screen. Nothing else crosses that
//  boundary: a platform's name and three numbers.

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var done: Int
        var total: Int
        var failed: Int
        var finished: Bool
        /// The phone's queue parked on cellular.
        var waitingForWiFi: Bool
    }

    /// The label the menu showed, the same one the notification uses.
    var platformName: String
}
#endif
