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
            id: "beetle-saturn",
            name: "Beetle Saturn",
            role: "Native Saturn core",
            summary: "GPL version 2, from the Mednafen project.",
            file: "beetle-saturn"
        ),
        Entry(
            id: "gambatte",
            name: "Gambatte",
            role: "Native Game Boy and Game Boy Color core",
            summary: "GPL version 2.",
            file: "gambatte"
        ),
        Entry(
            id: "mgba",
            name: "mGBA",
            role: "Native Game Boy Advance core",
            summary: "Mozilla Public License 2.0.",
            file: "mgba"
        ),
        Entry(
            id: "genesis-plus-gx",
            name: "Genesis Plus GX",
            role: "Native Genesis, Sega CD, Master System, Game Gear and 32X core",
            summary: "Free for non-commercial use, with the same distribution terms Cabinet already meets for FBNeo.",
            file: "genesis-plus-gx"
        ),
        Entry(
            id: "beetle-pce-fast",
            name: "Beetle PCE Fast",
            role: "Native TurboGrafx-16 and TurboGrafx-CD core",
            summary: "GPL version 2, from the Mednafen project.",
            file: "beetle-pce-fast"
        ),
        Entry(
            id: "snes9x",
            name: "Snes9x",
            role: "Native SNES core",
            summary: "Free for non-commercial use. Cabinet is free and is not sold, which satisfies those terms.",
            file: "snes9x"
        ),
        Entry(
            id: "fceumm",
            name: "FCEUmm",
            role: "Native NES core",
            summary: "GPL version 2.",
            file: "fceumm"
        ),
        Entry(
            id: "beetle-ngp",
            name: "Beetle NeoPop",
            role: "Native Neo Geo Pocket Color core",
            summary: "GPL version 2, from the Mednafen project.",
            file: "beetle-ngp"
        ),
        Entry(
            id: "prosystem",
            name: "ProSystem",
            role: "Native Atari 7800 core",
            summary: "GPL version 2.",
            file: "prosystem"
        ),
        Entry(
            id: "vecx",
            name: "vecx",
            role: "Native Vectrex core",
            summary: "GPL version 3. Bundles the Vectrex BIOS, which its rights holder has long permitted for non-commercial emulation use.",
            file: "vecx"
        ),
        Entry(
            id: "picodrive",
            name: "PicoDrive",
            role: "Native Sega 32X core",
            summary: "Free for non-commercial use. Cabinet is free and is not sold, which satisfies those terms.",
            file: "picodrive"
        ),
        Entry(
            id: "pcsx-rearmed",
            name: "PCSX ReARMed",
            role: "Native PlayStation core",
            summary: "GPL version 2.",
            file: "pcsx-rearmed"
        ),
        Entry(
            id: "flycast",
            name: "Flycast",
            role: "Native Dreamcast core",
            summary: "GPL version 2.",
            file: "flycast"
        ),
        Entry(
            id: "mupen64plus",
            name: "mupen64plus-libretro-nx (bundles GLideN64)",
            role: "Native Nintendo 64 core",
            summary: "GPL version 2. GLideN64, the RDP plugin this build uses, is bundled inside the same repository and is separately GPL version 2 as well.",
            file: "mupen64plus"
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
        Entry(
            id: "libchdr",
            name: "libchdr",
            role: "CHD disc image reading",
            summary: "Reads the compressed disc format the CD-based cores load, BSD licensed.",
            file: "libchdr"
        ),
        Entry(
            id: "zstd",
            name: "Zstandard",
            role: "Disc image decompression",
            summary: "Compression library by Meta, BSD licensed.",
            file: "zstd"
        ),
        Entry(
            id: "lzma",
            name: "LZMA SDK",
            role: "Archive decompression",
            summary: "Igor Pavlov's compression code, placed in the public domain.",
            file: "lzma"
        ),
        Entry(
            id: "tremor",
            name: "Tremor",
            role: "CD audio decoding",
            summary: "Xiph.Org's integer Ogg Vorbis decoder, used for CD audio tracks, BSD licensed.",
            file: "tremor"
        ),
        Entry(
            id: "inih",
            name: "inih",
            role: "Config parsing",
            summary: "Ben Hoyt's INI parser, built into mGBA, BSD licensed.",
            file: "inih"
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
                    #if os(iOS)
                    .textSelection(.enabled)
                    #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
