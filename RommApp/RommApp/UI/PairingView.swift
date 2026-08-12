#if os(iOS)
import SafariServices
#endif
#if os(tvOS)
import CoreImage.CIFilterBuiltins
#endif
import SwiftUI

/// Second screen. The app asks the server to start a pairing, shows the short
/// code, and waits.
///
/// The password is never typed here. Approval happens in RomM's own web UI
/// where the person is already signed in, which is the whole point of the
/// device authorization flow: this app never sees the password, and the token
/// it ends up holding can be revoked from the server without changing it.
///
/// iOS shows the code and opens an in-app Safari sheet to approve inline.
/// tvOS has no `SFSafariViewController` and no comfortable way to type into
/// a browser with a remote, so it shows the code and the approval URL as a
/// QR code instead: scan it with the phone that is already signed in to
/// RomM, approve there, and this screen dismisses itself once the poll below
/// sees the approval land. Same `startPairing()`/`completePairing()` calls
/// either way, only the display differs.
struct PairingView: View {
    @EnvironmentObject private var session: Session

    @State private var start: DeviceAuthInit?
    @State private var error: String?
    @State private var waiting = false
    #if os(iOS)
    @State private var showingApproval = false
    #endif
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        iosBody
        #endif
    }

    #if os(iOS)
    private var iosBody: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ScrollView {
                if landscape {
                    HStack(alignment: .top, spacing: 28) {
                        codePanel
                            .frame(maxWidth: .infinity, alignment: .leading)
                        instructions(landscape: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(24)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        heading
                        codePanel
                        instructions(landscape: false)
                    }
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            }
        }
        .onAppear { begin() }
        .onDisappear { pollTask?.cancel() }
        // An in-app Safari sheet instead of handing off to the real Safari
        // app: the device flow has no redirect to pull anyone back, so
        // leaving the app stranded people wondering whether to return by
        // hand. With the sheet, the app stays visibly underneath, and the
        // pairing poll dismisses it the moment approval lands. Note this
        // sheet does not share cookies with real Safari, so an existing
        // web session there does not carry over; a passkey login (Pocket
        // ID and the like) works inside it regardless.
        .sheet(isPresented: $showingApproval) {

            if let start, let url = session.approvalURL(for: start) {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: Pieces

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approve this device")
                .font(.largeTitle.bold())
            if let host = session.serverURL?.host {
                Text(host)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var codePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let start {
                Text("Your code")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(start.userCode)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .textSelection(.enabled)
            } else if error == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Asking the server for a code")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func instructions(landscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // In landscape the heading moves in here, beside the code, so the
            // two columns balance instead of one carrying everything.
            if landscape { heading }

            if let start {
                Button {
                    showingApproval = true
                } label: {
                    Text("Open RomM to approve")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                if waiting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for you to approve")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                Text("Sign in if asked, then approve the code. This closes on its own once approved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Try again") { begin() }
                    .buttonStyle(.bordered)
            }

            Button("Use a different server") { session.forgetServer() }
                .font(.footnote)
                .padding(.top, 4)
                // The last thing in the column, so it is the one that gets
                // clipped against the bottom edge without room of its own.
                .padding(.bottom, 16)
        }
    }
    #endif

    #if os(tvOS)
    private var tvBody: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Approve this device")
                    .font(.title.bold())
                if let host = session.serverURL?.host {
                    Text(host)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let start {
                    Text(start.userCode)
                        .font(.system(size: 64, weight: .bold, design: .monospaced))
                        .padding(.top, 24)

                    if let url = session.approvalURL(for: start) {
                        Text(url.absoluteString)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if waiting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Waiting for approval")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.top, 8)
                    }
                } else if error == nil {
                    ProgressView()
                        .padding(.top, 24)
                }

                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.top, 24)
                    Button("Try again") { begin() }
                }

                Button("Use a different server") { session.forgetServer() }
                    .padding(.top, 24)
            }
            .frame(maxWidth: 700, alignment: .leading)

            if let start, let url = session.approvalURL(for: start) {
                QRCodeView(url: url)
                    .frame(width: 320, height: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(80)
        .onAppear { begin() }
        .onDisappear { pollTask?.cancel() }
    }
    #endif

    // MARK: Flow

    private func begin() {
        pollTask?.cancel()
        start = nil
        error = nil
        waiting = false

        pollTask = Task {
            do {
                let started = try await session.startPairing()
                start = started
                waiting = true
                try await session.completePairing(started)
                #if os(iOS)
                // Approval landed while the Safari sheet was still up:
                // dismiss it explicitly rather than relying on this whole
                // view being swapped out from under an active sheet.
                showingApproval = false
                #endif
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                waiting = false
                #if os(iOS)
                showingApproval = false
                #endif
            }
        }
    }
}

#if os(iOS)
/// `SFSafariViewController` for the approval page. Real Safari under the
/// hood, so passkey prompts work, which a plain `WKWebView` would need a
/// special entitlement for.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .cancel
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif

#if os(tvOS)
/// Renders the approval URL as a QR code so a phone camera can jump straight
/// to it instead of someone typing a URL with a remote. `CIFilter`'s
/// built-in generator, no new dependency.
// Not private: TVAccountSwitcher.swift's own "add a profile" pairing flow
// reuses this exact renderer rather than a second copy. Still tvOS-only,
// still inside this file's #if os(tvOS) block, so nothing about iOS
// visibility changes.
struct QRCodeView: View {
    let url: URL

    var body: some View {
        if let image = Self.render(url.absoluteString) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private static func render(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // The generator's native output is a handful of pixels across; scale
        // it up with nearest-neighbor so the modules stay crisp on a TV.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
