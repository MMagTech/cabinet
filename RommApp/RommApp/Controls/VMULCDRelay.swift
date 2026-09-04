import Foundation

/// The bridge between Flycast's VMU LCD writes and the pairing wire:
/// the display half of the phone-as-VMU design, and the only half that
/// exists on tvOS (the television never hosts VMU play, his call, both
/// reasons recorded in the roadmap: the minigame's identity is the
/// thing you take AWAY from the TV, and 48x32 is absurd on a living
/// room screen).
///
/// Flycast's push_vmu_screen (patched in tools/build-flycast.sh) calls
/// through a function pointer installed here via an exported setter,
/// resolved with dlsym like cabinetPvrQueueDepth: a build whose core
/// predates the patch resolves nothing and streams nothing. The
/// callback fires on whatever thread the emulated maple bus is serviced
/// from, so everything it touches is behind a lock, and the packed
/// frame is handed onward only when it actually changed; games rewrite
/// identical frames freely, and the wire only wants change.
///
/// A singleton because the C callback carries no context pointer; the
/// player view installs a handler for the session and clears it after.
final class VMULCDRelay {
    static let shared = VMULCDRelay()

    /// Where a changed frame goes: 192 packed bytes, row-major, 8
    /// pixels per byte, bit 7 leftmost, the wire's own format. Called
    /// off the main thread.
    private var onFrame: ((Data) -> Void)?
    private var last: Data?
    private let lock = NSLock()

    private typealias Callback = @convention(c) (Int32, UnsafePointer<UInt8>?) -> Void
    private typealias Setter = @convention(c) (Callback?) -> Void

    private func setter() -> Setter? {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "cabinetSetVMUScreenCallback") else { return nil }
        return unsafeBitCast(sym, to: Setter.self)
    }

    /// Starts a session's stream. Whether a core new enough to have the
    /// hook is present decides everything; callers need not know.
    func install(onFrame: @escaping (Data) -> Void) {
        lock.lock()
        self.onFrame = onFrame
        last = nil
        lock.unlock()
        setter()? { vmuID, buffer in
            // Player one's primary VMU alone (bus 0, slot 0, the card
            // this app's save sync captures as vmu_save_A1); the
            // companion window is that card's window.
            guard vmuID == 0, let buffer else { return }
            VMULCDRelay.shared.push(buffer)
        }
    }

    func uninstall() {
        setter()?(nil)
        lock.lock()
        onFrame = nil
        last = nil
        lock.unlock()
    }

    private func push(_ buffer: UnsafePointer<UInt8>) {
        // One byte per pixel in, one bit per pixel out: 48x32 to 192.
        var packed = Data(count: 192)
        packed.withUnsafeMutableBytes { raw in
            guard let out = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<192 {
                var byte: UInt8 = 0
                for bit in 0..<8 where buffer[i * 8 + bit] != 0 {
                    byte |= UInt8(0x80 >> bit)
                }
                out[i] = byte
            }
        }
        lock.lock()
        let changed = packed != last
        if changed { last = packed }
        let handler = onFrame
        lock.unlock()
        if changed { handler?(packed) }
    }
}
