// Harness-only stand-in for the ObjC LibretroFrontend the app links. The
// controls layer touches exactly one symbol on it (rumble routing), and
// the harness has no core to rumble.
import Foundation

enum LibretroFrontend {
    static func setRumbleHandler(_ handler: ((Int, Bool, UInt16) -> Void)?) {}
}
