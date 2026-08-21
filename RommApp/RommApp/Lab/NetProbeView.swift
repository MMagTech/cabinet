import SwiftUI
#if os(iOS)
import CoreMotion
#endif

/// The probe's screens. See NetProbe.swift for what is being measured and
/// why; nothing here is a product surface, both screens exist so a human
/// glancing at a device mid-run can tell it is alive and roughly healthy.
///
/// The sender screen is also part of the test conditions on purpose: it
/// keeps a 60fps animation running, samples CoreMotion at the same 100Hz a
/// real control panel would, and holds the idle timer off, because the
/// radio behaves differently under exactly this load and a quiet screen
/// measures the wrong phone.
struct NetProbeView: View {
    let role: NetProbe.Role

    var body: some View {
        switch role {
        case .sender(let transport):
            NetProbeSenderView(engine: ProbeSenderEngine(transport: transport))
        case .receiver:
            NetProbeReceiverView(engine: ProbeReceiverEngine())
        }
    }
}

private struct NetProbeSenderView: View {
    @StateObject var engine: ProbeSenderEngine
    #if os(iOS)
    @State private var motion = CMMotionManager()
    #endif

    var body: some View {
        VStack(spacing: 16) {
            Text("Cabinet link probe").font(.headline)
            Text("\(engine.transport.label) at \(Int(NetProbe.sendHz))Hz for \(Int(NetProbe.minutes)) min")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(engine.status).font(.callout)

            // The load half of the test conditions: something the GPU has
            // to redraw every frame, like a control panel would.
            TimelineView(.animation) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) * 180
                RoundedRectangle(cornerRadius: 8)
                    .fill(engine.done ? .green : .orange)
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(angle))
            }
            .frame(height: 80)

            Grid(alignment: .leading, horizontalSpacing: 24) {
                GridRow {
                    Text("sent")
                    Text("\(engine.counters.packets)").monospacedDigit()
                }
                GridRow {
                    Text("send drops")
                    Text("\(engine.counters.sendDrops)").monospacedDigit()
                }
                GridRow {
                    Text("last round trip")
                    Text(String(format: "%.1f ms", engine.counters.lastRTTMS)).monospacedDigit()
                }
            }
            .font(.body)
        }
        .padding()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            #if os(iOS)
            // Same cadence the real controller would sample at. The values
            // are discarded; only the load is wanted.
            if motion.isDeviceMotionAvailable {
                motion.deviceMotionUpdateInterval = 1.0 / NetProbe.sendHz
                motion.startDeviceMotionUpdates(to: .init()) { _, _ in }
            }
            #endif
            engine.start()
        }
    }
}

private struct NetProbeReceiverView: View {
    @StateObject var engine: ProbeReceiverEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Cabinet link probe, receiving").font(.headline)

            ForEach(NetProbe.Transport.allCases, id: \.rawValue) { transport in
                let c = engine.counters[transport] ?? ProbeCounters()
                HStack(spacing: 24) {
                    Text(transport.label).frame(width: 80, alignment: .leading)
                    Text("\(c.packets) pkts").monospacedDigit()
                    Text(String(format: "max gap %.0f ms", c.maxGapMS)).monospacedDigit()
                    Text("over 25ms: \(c.gapsOver25)").monospacedDigit()
                    Text("over 100ms: \(c.gapsOver100)").monospacedDigit()
                }
                .font(.body.monospacedDigit())
            }

            ForEach(engine.status.indices, id: \.self) { i in
                Text(engine.status[i]).font(.caption).foregroundStyle(.secondary)
            }

            // Closing the traces is a remote-click on purpose: the
            // receiver has no natural end, and the trailer it writes is
            // what tells a scripted pull the file is a finished result.
            Button("End session and close traces") { engine.finish() }
        }
        .padding(48)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            engine.start()
        }
    }
}
