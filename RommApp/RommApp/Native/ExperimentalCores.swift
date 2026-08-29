import Foundation

/// The experimental switch: whether platforms above the JIT boundary are
/// offered natively on this device.
///
/// The classification is architectural rather than measured, so it does
/// not go stale: platforms below the boundary run natively because an
/// interpreter is genuinely enough for their hardware. The platforms
/// marked experimental run natively through brute force, their cores
/// want a dynamic recompiler this process is not allowed to carry, and a
/// handful of benched games is not a promise about a whole library. The
/// deliberate flip is the point: speed varies, and the person turning it
/// on chose that trade.
///
/// Stored per device on purpose. The phone and the television share the
/// rule, not the answer, and each carries its own switch.
enum ExperimentalCores {
    static let key = "experimentalCoresEnabled"

    /// The launch argument exists for the bench harness and lab
    /// automation, which must reach gated cores without flipping a
    /// setting that would outlive the run.
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: key)
            || ProcessInfo.processInfo.arguments.contains("-cabinetExperimentalCores")
    }
}

extension NativePlatform {
    /// Platforms offered natively only behind the experimental switch.
    /// Saturn is deliberately absent (Beetle Saturn is interpreter-only
    /// upstream by design) and so is PSP (full speed without a
    /// recompiler is PPSSPP's own design claim, verified in the lab).
    /// Dreamcast and N64 are here because their cores are built around
    /// recompilers they cannot use in this process, and both have known
    /// rough edges an interpreter cannot buy back.
    var isExperimental: Bool {
        switch self {
        case .dreamcast, .n64: return true
        default: return false
        }
    }
}
