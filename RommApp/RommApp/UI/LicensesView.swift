import SwiftUI

/// Every piece of software this app ships, with its license readable in
/// full. Entries are data, not views, so adding the next native core is
/// one line here plus its bundled text file.
///
/// Only what the app binary actually contains belongs in this list. The
/// web player's emulators (MAME 2003, FB Alpha and the rest) run inside
/// RomM's own page served by the person's server; this app does not bundle
/// them, so they are RomM's attribution to make, not Cabinet's.
struct LicensesView: View {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let role: String
        /// The one fact worth reading, above the legal text nobody does.
        let summary: String
        /// Bundled text file in Resources/Licenses, without extension.
        let file: String
    }

    static let entries: [Entry] = [
        Entry(
            id: "cabinet",
            name: "Cabinet",
            role: "This app",
            summary: "Cabinet itself is free software under the MIT license.",
            file: "cabinet-mit"
        ),
        Entry(
            id: "fbneo",
            name: "FinalBurn Neo",
            role: "Native arcade core",
            summary: "FBNeo permits free non-commercial use. Cabinet is free, is not sold, and takes no donations, which satisfies those terms. FBNeo builds on code from the MAME project and is subject to MAME's license as well.",
            file: "fbneo"
        ),
        Entry(
            id: "libretro-common",
            name: "libretro-common",
            role: "Emulator interface",
            summary: "The libretro API and utility code FBNeo's core is built against, MIT licensed.",
            file: "libretro-common"
        ),
        Entry(
            id: "zlib",
            name: "zlib",
            role: "ROM decompression",
            summary: "Compression library by Jean-loup Gailly and Mark Adler, zlib license.",
            file: "zlib"
        ),
    ]

    var body: some View {
        List(Self.entries) { entry in
            NavigationLink {
                LicenseTextView(entry: entry)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text(entry.role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseTextView: View {
    let entry: LicensesView.Entry

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: entry.file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "The license text is missing from this build. The canonical text ships with the project's source."
        }
        return text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.summary)
                    .font(.callout)
                Text(licenseText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
