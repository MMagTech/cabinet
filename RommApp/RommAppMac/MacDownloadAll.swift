//  Download All on the Mac: the platform's context menu, the
//  confirmation on the shell, and the sidebar's status line. The
//  coordinator, the prompt and the menu items themselves are shared with
//  the phone in DownloadAll.swift; this file is only what a Mac adds,
//  Show in Finder and File > Download All….

import SwiftUI

/// A platform's context menu on the Mac: Download All, Remove All
/// Downloads, Show in Finder, on the sidebar row and the Library tile,
/// and without Download All in Downloaded. One vocabulary for a
/// platform wherever it is met. (A menu drawn twice over itself was
/// chased through this file's item count for an evening; it was
/// MacWindow's title bar poll, since removed, and the count is free.)
struct MacPlatformMenu: View {
    let platform: Platform
    let label: String
    /// Off in Downloaded, where a platform is what is already on disk
    /// and an offer to download it reads as nonsense.
    var offersDownloadAll = true
    @ObservedObject private var store = KeptGameStore.shared

    var body: some View {
        PlatformDownloadMenuItems(platform: platform, label: label, offersDownloadAll: offersDownloadAll)
        Button {
            if let folder = store.mirrorRomsFolder(platformFsSlug: platform.fsSlug) {
                UIApplication.shared.open(folder)
            }
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .disabled(store.mirrorRomsFolder(platformFsSlug: platform.fsSlug) == nil)
    }
}

/// The shared confirmation, plus File > Download All… for the platform
/// the sidebar shows.
struct MacDownloadAllPrompt: ViewModifier {
    @EnvironmentObject private var session: Session

    func body(content: Content) -> some View {
        content
            .downloadAllPrompt()
            .onReceive(NotificationCenter.default.publisher(for: .cabinetDownloadAllSelected)) { _ in
                guard let selected = MacChrome.shared.selectedPlatform else { return }
                DownloadAll.shared.prepare(selected.platform, name: selected.label, session: session)
            }
    }
}

extension View {
    func macDownloadAllPrompt() -> some View { modifier(MacDownloadAllPrompt()) }
}

/// The sidebar's status line while a platform downloads, at its foot,
/// the way Photos reports its own uploads and downloads there. Visible
/// from every screen, interrupting none, and gone when the queue is.
struct MacDownloadAllStatus: View {
    @ObservedObject private var store = KeptGameStore.shared

    var body: some View {
        if store.bulk != nil {
            DownloadAllStatusContent()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
        }
    }
}
