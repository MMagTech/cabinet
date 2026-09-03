//  Cabinet's Settings window on the Mac.
//
//  Apple's guidance for a Settings window, read 2026-09-02: opened from
//  the app menu at Cmd+comma, a standard window that is not modal, a
//  noncustomizable toolbar of panes that always shows the active one,
//  sized to the pane, minimize and zoom dimmed, and the last pane
//  restored next time. This is that window. The phone and TV keep
//  SettingsView, the scrolling list, which is theirs.
//
//  A TabView, because Catalyst hoists a tab bar into the window's title
//  bar as exactly that toolbar of panes. MacWindow leaves this scene
//  alone; everything it does to the shell's title bar would strip the
//  panes off this one.
//
//  Tasks open as sheets on this window, remapping and pairing and the
//  storage list, since a pane does not push. Cores keeps a stack inside
//  its pane, one platform's options at a time, which is the one
//  compromise here and a small one.

import SwiftUI

struct MacSettingsWindow: View {
    static let windowID = "cabinet-settings"

    @EnvironmentObject private var session: Session
    @AppStorage("com.mmagtech.RommApp.macSettingsPane") private var pane = Pane.controllers.rawValue

    enum Pane: String, CaseIterable {
        case controllers, library, server, cores
        var title: String {
            switch self {
            case .controllers: return "Controllers"
            case .library: return "Library"
            case .server: return "Server"
            case .cores: return "Cores"
            }
        }
        var symbol: String {
            switch self {
            case .controllers: return "gamecontroller"
            case .library: return "books.vertical"
            case .server: return "server.rack"
            case .cores: return "cpu"
            }
        }
    }

    private var selection: Binding<Pane> {
        Binding(get: { Pane(rawValue: pane) ?? .controllers }, set: { pane = $0.rawValue })
    }

    var body: some View {
        TabView(selection: selection) {
            Tab(Pane.controllers.title, systemImage: Pane.controllers.symbol, value: Pane.controllers) {
                ControllersPane()
            }
            Tab(Pane.library.title, systemImage: Pane.library.symbol, value: Pane.library) {
                LibraryPane()
            }
            Tab(Pane.server.title, systemImage: Pane.server.symbol, value: Pane.server) {
                ServerPane()
            }
            Tab(Pane.cores.title, systemImage: Pane.cores.symbol, value: Pane.cores) {
                NavigationStack { NativeCoresView() }
            }
        }
        .background(MacSettingsSceneTag(title: (Pane(rawValue: pane) ?? .controllers).title))
        .frame(width: 640, height: 520)
    }
}

/// Finds the scene this window lives in, registers it with MacWindow
/// as the Settings scene so the shell styling skips it, sizes it, and
/// keeps the window title on the pane.
private struct MacSettingsSceneTag: UIViewRepresentable {
    let title: String

    func makeUIView(context: Context) -> TagView { TagView() }

    func updateUIView(_ view: TagView, context: Context) {
        view.title = title
        view.register()
    }

    final class TagView: UIView {
        var title = ""
        override func didMoveToWindow() {
            super.didMoveToWindow()
            register()
        }
        func register() {
            guard let scene = window?.windowScene else { return }
            MacWindow.adoptSettingsScene(scene, title: title)
        }
    }
}

// MARK: Panes

private struct ControllersPane: View {
    @AppStorage("com.mmagtech.RommApp.rumbleEnabled") private var rumbleEnabled = true
    @State private var remapping = false
    @State private var pairing = false

    var body: some View {
        Form {
            Section {
                ControllerStatusRow()
                Button("Change Buttons…") { remapping = true }
                Button("Phone Controller…") { pairing = true }
                Toggle("Rumble", isOn: $rumbleEnabled)
            } footer: {
                Text("Games are played with a controller. Pair one to this Mac over Bluetooth.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $remapping) {
            NavigationStack {
                ControllerRemapView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { remapping = false } } }
            }
        }
        .sheet(isPresented: $pairing) {
            NavigationStack {
                MacPhonePairingView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { pairing = false } } }
            }
        }
        .task { GameControllerManager.shared.start() }
    }
}

/// No Manage Storage here. The phone's Storage sheet is half web
/// player cache, which the Mac has no player for, and half a kept
/// list the sidebar's Downloaded already is; single games come off
/// through their own right-click and whole platforms through theirs.
private struct LibraryPane: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var keptStore = KeptGameStore.shared

    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cabinet", isDirectory: true)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Downloaded games", value: "\(keptStore.games.count)")
                LabeledContent("On disk", value: ByteCountFormatter.string(fromByteCount: keptStore.totalBytes, countStyle: .file))
                Button("Show in Finder") { UIApplication.shared.open(folder) }
            } header: {
                Text("Storage")
            } footer: {
                Text("Games kept on this Mac, in Documents/Cabinet.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ServerPane: View {
    @EnvironmentObject private var session: Session
    @State private var editingAddress = false
    @State private var confirmingSignOut = false
    @State private var confirmingSwitch = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Server", value: session.serverURL?.host ?? "unknown")
                if let version = session.serverVersion {
                    LabeledContent("RomM version", value: version)
                }
                LabeledContent("Second address", value: session.localServerURL?.host ?? "Not set")
                Button("Change Second Address…") { editingAddress = true }
                if session.localServerURL != nil {
                    LabeledContent("Using", value: session.isUsingLocalAddress ? "Local network" : "Internet")
                }
            } footer: {
                Text("If your server has a second address, Cabinet uses whichever one is on this network.")
            }
            Section {
                Button("Sign Out…", role: .destructive) { confirmingSignOut = true }
                Button("Switch Server…", role: .destructive) { confirmingSwitch = true }
            } footer: {
                Text("Signing out keeps the server. Switching servers forgets everything.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editingAddress) {
            NavigationStack {
                LocalAddressView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editingAddress = false } } }
            }
            .environmentObject(session)
        }
        .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                WidgetWriter.wipe()
                SpotlightIndexer.wipe()
                session.signOut()
            }
        } message: {
            Text("You will need to approve this Mac again to reconnect.")
        }
        .confirmationDialog("Switch server?", isPresented: $confirmingSwitch, titleVisibility: .visible) {
            Button("Switch Server", role: .destructive) {
                WidgetWriter.wipe()
                SpotlightIndexer.wipe()
                session.forgetServer()
            }
        } message: {
            Text("The saved address and pairing are removed.")
        }
    }
}
