#if os(tvOS)
import SwiftUI

/// The signed-in RomM username beside a small circular avatar, in Home's
/// top-right corner: the real RomM avatar when one has been fetched, a
/// generic person glyph otherwise. Reserved for this since before this
/// feature existed (see tvos-account-switching-design).
struct TVAccountChip: View {
    @EnvironmentObject private var session: Session
    @State private var showingSwitcher = false
    @State private var avatarImage: UIImage?

    private var activeProfile: TVProfile? { TVProfileStore.activeProfile }

    private var label: String {
        activeProfile?.label ?? session.serverURL?.host ?? "Account"
    }

    var body: some View {
        Button {
            showingSwitcher = true
        } label: {
            HStack(spacing: 12) {
                Text(label)
                    .lineLimit(1)
                Group {
                    if let avatarImage {
                        Image(uiImage: avatarImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(RowFocusStyle(cornerRadius: 999))
        .fullScreenCover(isPresented: $showingSwitcher) {
            TVAccountSwitcherView()
        }
        // id-scoped to the active profile, not a bare .onAppear: switching
        // profiles has to swap this image too, not just the switcher's
        // own list.
        .task(id: activeProfile?.id) {
            guard let activeProfile else { return }
            avatarImage = UIImage(contentsOfFile: TVProfileStore.avatarURL(for: activeProfile.id).path)
            guard avatarImage == nil else { return }
            // Missing means either a build from before avatar fetching
            // existed (the profile was created with no attempt ever
            // made), or a transient failure at creation time. Either way
            // retry live rather than sitting on a permanently blank
            // avatar, then poll briefly for the file this kicks off in
            // the background to actually land.
            TVProfileStore.enrichIfNeeded(activeProfile)
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                if let image = UIImage(contentsOfFile: TVProfileStore.avatarURL(for: activeProfile.id).path) {
                    avatarImage = image
                    return
                }
            }
        }
    }
}

/// The switcher itself: every paired profile as a row, Add Profile at the
/// bottom, an optional PIN gate in front of an actual switch. Same glass/
/// RowFocusStyle discipline as every other tvOS screen built this session,
/// not a one-off.
struct TVAccountSwitcherView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    @AppStorage("com.mmagtech.RommAppTV.requirePINToSwitch") private var requirePIN = false
    @AppStorage("com.mmagtech.RommAppTV.switchPIN") private var storedPIN = ""

    @State private var profiles: [TVProfile] = []
    @State private var pendingSwitch: TVProfile?
    @State private var addingProfile = false

    private var knownServerURL: URL? {
        TVProfileStore.activeProfile.flatMap { URL(string: $0.serverURLString) } ?? session.serverURL
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Accounts")
                        .font(.largeTitle.weight(.bold))
                        .padding(.bottom, 8)

                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }

                    Button {
                        addingProfile = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("Add a profile")
                            Spacer()
                        }
                        .font(.title3)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(RowFocusStyle())
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 80)
                .padding(.vertical, 50)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        // A real opaque backdrop, not decoration: a fullScreenCover on
        // tvOS does not paint one of its own, so without this the screen
        // underneath (Settings, or Home) shows straight through and the
        // two read as a single garbled screen. Same lesson TVGameLaunchView
        // already learned; missed here when this screen was first built.
        .tvModalBackdrop()
        .onAppear { profiles = TVProfileStore.profiles }
        .fullScreenCover(isPresented: $addingProfile) {
            // The server is already known: this household's first
            // profile (set up through ServerSetupView/PairingView like
            // any first launch) already established it, so a second
            // profile never needs to ask for an address again, only pair
            // a new account against the same one. Falls back to nothing
            // (the button below is simply hidden) on the practically
            // impossible case neither source has a URL yet.
            if let knownServerURL {
                TVAddProfileView(serverURL: knownServerURL) { added in
                    profiles = TVProfileStore.profiles
                    if added { dismiss() }
                }
            }
        }
        // A full-screen numeric keypad, not `.alert` with a `SecureField`:
        // tvOS alerts have no text-input pattern the way iOS's do, there
        // is no on-screen keyboard a remote can drive inside one. An
        // on-screen number pad, focus-navigable like everything else
        // here, is the actual tvOS convention for PIN entry.
        .fullScreenCover(item: $pendingSwitch) { profile in
            TVPINEntryView(expected: storedPIN) { matched in
                if matched {
                    TVProfileStore.activate(profile, session: session)
                    pendingSwitch = nil
                    dismiss()
                } else {
                    pendingSwitch = nil
                }
            }
        }
    }

    private func profileRow(_ profile: TVProfile) -> some View {
        let active = profile.id == TVProfileStore.activeProfileID
        return Button {
            guard !active else { return }
            requestSwitch(to: profile)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.label)
                        .font(.title3)
                    if let host = profile.host {
                        Text(host)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 24)
                if active {
                    Label("Current", systemImage: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowFocusStyle())
        .disabled(active)
    }

    private func requestSwitch(to profile: TVProfile) {
        guard requirePIN, !storedPIN.isEmpty else {
            TVProfileStore.activate(profile, session: session)
            dismiss()
            return
        }
        pendingSwitch = profile
    }
}

/// A standalone pairing flow against its own `RommClient`, independent of
/// the live `Session`: the switcher can be reached mid-session from Home,
/// and resetting the actual app-wide `Session` to add a second profile
/// would blow the whole app back to setup screens out from under whoever
/// is still signed in. Only `TVProfileStore` is touched, and only once
/// this succeeds.
private struct TVAddProfileView: View {
    /// Never optional by the time this view is reachable: the household's
    /// first profile (ServerSetupView/PairingView through the live
    /// Session, at first launch) always establishes a server before
    /// Add A Profile is ever visible anywhere. A second profile pairs a
    /// different account against that same server, never a different
    /// one, so there is no address step to ask here.
    let serverURL: URL
    let completion: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case pairing(client: RommClient)
        case naming(client: RommClient, token: String)
    }

    @State private var step: Step

    init(serverURL: URL, completion: @escaping (Bool) -> Void) {
        self.serverURL = serverURL
        self.completion = completion
        _step = State(initialValue: .pairing(client: RommClient(baseURL: serverURL)))
    }

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { completion(false); dismiss() }
                    }
                }
        }
        // Same reason as TVAccountSwitcherView: a fullScreenCover paints
        // no backdrop of its own on tvOS.
        .tvModalBackdrop()
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .pairing(let client):
            pairingStep(client: client, serverURL: serverURL)
        case .naming(let client, let token):
            namingStep(client: client, serverURL: serverURL, token: token)
        }
    }

    private func pairingStep(client: RommClient, serverURL: URL) -> some View {
        TVAddProfilePairingStep(client: client, serverURL: serverURL) { token in
            step = .naming(client: client, token: token)
        }
    }

    private func namingStep(client: RommClient, serverURL: URL, token: String) -> some View {
        TVAddProfileNamingStep(client: client, defaultName: serverURL.host ?? "Profile") { label, avatar in
            let profile = TVProfile(id: UUID(), label: label, serverURLString: serverURL.absoluteString)
            TVProfileStore.addProfile(profile, token: token)
            if let avatar { TVProfileStore.saveAvatar(avatar, for: profile.id) }
            completion(true)
        }
    }
}

private struct TVAddProfilePairingStep: View {
    let client: RommClient
    let serverURL: URL
    let onApproved: (String) -> Void

    @State private var start: DeviceAuthInit?
    @State private var error: String?
    @State private var waiting = false
    @State private var pollTask: Task<Void, Never>?

    private var approvalURL: URL? {
        guard let start else { return nil }
        return URL(string: serverURL.absoluteString + start.verificationPathComplete)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Approve this device")
                    .font(.title.bold())
                Text(serverURL.host ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let start {
                    Text(start.userCode)
                        .font(.system(size: 64, weight: .bold, design: .monospaced))
                        .padding(.top, 24)
                    if let approvalURL {
                        Text(approvalURL.absoluteString)
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
                    ProgressView().padding(.top, 24)
                }

                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).padding(.top, 24)
                    Button("Try again") { begin() }
                }
            }
            .frame(maxWidth: 700, alignment: .leading)

            if let approvalURL {
                QRCodeView(url: approvalURL)
                    .frame(width: 320, height: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(80)
        .onAppear { begin() }
        .onDisappear { pollTask?.cancel() }
    }

    private func begin() {
        pollTask?.cancel()
        start = nil
        error = nil
        waiting = false
        pollTask = Task {
            do {
                let started = try await client.startDeviceAuth()
                start = started
                waiting = true
                let token = try await client.awaitDeviceApproval(started)
                onApproved(token.accessToken)
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                waiting = false
            }
        }
    }
}

private struct TVAddProfileNamingStep: View {
    /// The RomM username the just-approved account actually belongs to,
    /// fetched fresh, not guessed at from the server address. The client
    /// passed in already carries the token this pairing just produced.
    let client: RommClient
    let defaultName: String
    /// The real avatar photo, if `/api/users/{id}/avatar` answered in
    /// time, handed back alongside the chosen label so the caller can
    /// save it once the profile's own id actually exists.
    let onSave: (String, Data?) -> Void

    @State private var name = ""
    @State private var avatarData: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Name this profile")
                .font(.largeTitle.weight(.bold))
            Text("This is what shows in the switcher. Your own name, or whoever this profile is for.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(defaultName, text: $name)
                .font(.title3)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background {
                    if #available(tvOS 26.0, *) {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.clear)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                    }
                }
            Button {
                onSave(name.isEmpty ? defaultName : name, avatarData)
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(RowFocusStyle())
        }
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(80)
        .onAppear {
            name = defaultName
            Task {
                guard let user = try? await client.currentUser() else { return }
                // Only overwrite if nothing has changed it in the
                // meantime: a fast typist's own edit should never get
                // silently clobbered by a network response landing late.
                if name == defaultName { name = user.username }
                avatarData = try? await client.avatarData(userId: user.id)
            }
        }
    }
}

/// A 4-digit on-screen keypad, the actual tvOS convention for PIN entry
/// (matching the shape of Apple's own passcode screens): no text field,
/// no keyboard, digits as real focus-navigable buttons a remote drives
/// directly. Calls back with whether the entry matched once 4 digits are
/// in, success or not; the caller decides what happens either way.
private struct TVPINEntryView: View {
    let expected: String
    let onResult: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    @State private var wrongAttempt = false

    private let columns = [GridItem(.fixed(120)), GridItem(.fixed(120)), GridItem(.fixed(120))]

    var body: some View {
        VStack(spacing: 32) {
            Text("Enter PIN")
                .font(.title.weight(.semibold))

            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 2)
                        .background {
                            Circle().fill(index < entry.count ? Color.primary : Color.clear)
                        }
                        .frame(width: 20, height: 20)
                }
            }

            if wrongAttempt {
                Text("That PIN didn't match.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(1...9, id: \.self) { digit in
                    digitButton(String(digit))
                }
                Color.clear.frame(width: 120, height: 80)
                digitButton("0")
                Button {
                    entry = String(entry.dropLast())
                } label: {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .frame(width: 120, height: 80)
                }
                .buttonStyle(RowFocusStyle())
            }

            Button("Cancel") {
                onResult(false)
                dismiss()
            }
            .buttonStyle(TextFocusStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvModalBackdrop()
        .onChange(of: entry) { _, newValue in
            guard newValue.count == 4 else { return }
            if newValue == expected {
                onResult(true)
                dismiss()
            } else {
                wrongAttempt = true
                entry = ""
            }
        }
    }

    private func digitButton(_ digit: String) -> some View {
        Button {
            wrongAttempt = false
            guard entry.count < 4 else { return }
            entry += digit
        } label: {
            Text(digit)
                .font(.title2.weight(.semibold))
                .frame(width: 120, height: 80)
        }
        .buttonStyle(RowFocusStyle())
    }
}

/// Settings' own "Set a PIN" flow: enter 4 digits, then enter them again
/// to confirm before it's actually saved, so a mistyped PIN doesn't lock
/// someone out of switching later with no way to know what they typed.
/// Not `private`: `TVSettingsView.swift` presents it directly.
struct TVSetPINView: View {
    let onSet: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case enter
        case confirm(pin: String)
        case mismatch
    }

    @State private var step: Step = .enter
    @State private var entry = ""

    var body: some View {
        VStack(spacing: 32) {
            switch step {
            case .enter:
                Text("Choose a 4-digit PIN").font(.title.weight(.semibold))
            case .confirm:
                Text("Enter it again to confirm").font(.title.weight(.semibold))
            case .mismatch:
                Text("Those didn't match. Try again.").font(.title.weight(.semibold)).foregroundStyle(.red)
            }

            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 2)
                        .background {
                            Circle().fill(index < entry.count ? Color.primary : Color.clear)
                        }
                        .frame(width: 20, height: 20)
                }
            }

            LazyVGrid(columns: [GridItem(.fixed(120)), GridItem(.fixed(120)), GridItem(.fixed(120))], spacing: 20) {
                ForEach(1...9, id: \.self) { digit in digitButton(String(digit)) }
                Color.clear.frame(width: 120, height: 80)
                digitButton("0")
                Button {
                    entry = String(entry.dropLast())
                } label: {
                    Image(systemName: "delete.left").font(.title2).frame(width: 120, height: 80)
                }
                .buttonStyle(RowFocusStyle())
            }

            Button("Cancel") { dismiss() }
                .buttonStyle(TextFocusStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvModalBackdrop()
        .onChange(of: entry) { _, newValue in
            guard newValue.count == 4 else { return }
            switch step {
            case .enter:
                step = .confirm(pin: newValue)
                entry = ""
            case .confirm(let pin):
                if newValue == pin {
                    onSet(pin)
                    dismiss()
                } else {
                    step = .mismatch
                    entry = ""
                }
            case .mismatch:
                step = .enter
                entry = ""
            }
        }
    }

    private func digitButton(_ digit: String) -> some View {
        Button {
            guard entry.count < 4 else { return }
            entry += digit
        } label: {
            Text(digit).font(.title2.weight(.semibold)).frame(width: 120, height: 80)
        }
        .buttonStyle(RowFocusStyle())
    }
}
#endif
