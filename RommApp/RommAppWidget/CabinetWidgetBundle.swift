import SwiftUI
import WidgetKit

/// The widget extension's entry point. A WidgetKit extension names no
/// principal class in its Info.plist: this attribute is the entire
/// hookup, and adding a principal class as well is how a widget fails to
/// load with nothing useful in the log.
@main
struct CabinetWidgetBundle: WidgetBundle {
    var body: some Widget {
        CabinetWidget()
        DownloadActivityWidget()
    }
}
