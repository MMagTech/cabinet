import Foundation

/// The same loop the WASM module runs, written in Swift.
///
/// Swift is compiled ahead of time and runs at full native speed, so this is
/// the reference the webview number gets judged against. Both run on the same
/// chip in the same app, which removes every variable except how the webview
/// executes WASM.
///
/// Build Release before believing the native number. A Debug build compiles
/// this at -Onone and will understate it badly.
enum NativeBench {
    static let iterations: Int32 = 30_000_000

    /// Returns the same checksum the WASM and JavaScript versions produce.
    @inline(never)
    static func run(_ n: Int32) -> Int32 {
        var acc: Int32 = 1
        var i: Int32 = 0
        while i < n {
            acc = acc &* 1_664_525 &+ 1_013_904_223
            acc = acc ^ Int32(bitPattern: UInt32(bitPattern: acc) >> 13)
            i &+= 1
        }
        return acc
    }

    /// Millions of iterations per second, plus the checksum for cross checking.
    static func measure() -> (millionPerSec: Double, checksum: Int32) {
        _ = run(2_000_000)  // warm up, matching what the page does

        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = run(iterations)
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start

        let ms = Double(elapsedNs) / 1_000_000
        return (Double(iterations) / ms / 1000, checksum)
    }
}
