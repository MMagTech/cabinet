// Dumps the arcade control layouts, which are generated in code rather
// than bundled as files, into real JSON layouts the LayoutEditor can
// open and Marcus can tune like every other system.
//
// Fidelity is by construction, not by transcription: this compiles the
// player's own ArcadeLayout generator AND the editor's own exporter, so
// the files it writes are exactly what the generator produces and
// exactly the shape the editor round trips.
//
// Run: sh tools/arcade-layouts/run.sh   (writes into Resources/ControlLayouts)

import Foundation

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func rect(_ r: ControlLayout.Rect) -> EditRect {
    EditRect(x: r.x, y: r.y, w: r.w, h: r.h)
}

func item(_ i: ControlLayout.Item) -> EditableItem {
    EditableItem(
        kind: i.kind, label: i.label, input: i.input, inputs: i.inputs,
        frame: rect(i.frame), extended: rect(i.extended), fourWay: i.fourWay
    )
}

/// One file per geometric variant. The stick kind and the button count
/// are what actually move controls around; four-way-ness is a behaviour
/// flag the player re-applies from the game's own profile at load, so it
/// deliberately does not split the files.
struct Variant {
    let file: String
    let dualStick: Bool
    let buttons: Int
}

var variants: [Variant] = []
for n in 0...6 {
    variants.append(Variant(file: "arcade-stick\(n)", dualStick: false, buttons: n))
    variants.append(Variant(file: "arcade-twin\(n)", dualStick: true, buttons: n))
}

let ergonomics = """
Generated from ArcadeLayout.build and then tuned by hand. The stick sits \
low in the left thumb's arc pivoting from the bottom corner grip; action \
buttons curl through the right thumb's arc; Coin, Start and Menu take the \
top band where mid-game thumbs never stray. A twin-stick game shrinks the \
movement stick to give the aiming stick the right thumb's whole arc.
"""

var written = 0
for v in variants {
    let profile = ArcadeProfile(
        profile: v.dualStick ? "dual_stick" : "six_button",
        buttons: v.buttons,
        ways: "8",
        coins: 1,
        parent: nil,
        vertical: false
    )
    let generated = ArcadeLayout.build(for: profile)
    let layout = EditableLayout(
        name: v.file,
        // The player overwrites this with the running game's own system
        // string, which carries the profile name and drives the palette.
        // Kept meaningful here so the editor colours the preview sanely.
        system: generated.system,
        ergonomics: ergonomics,
        headroom: generated.headroom,
        items: generated.items.map(item),
        landscapeItems: generated.landscapeItems?.map(item)
    )
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(v.file).json")
    do {
        try layout.jsonText().data(using: .utf8)!.write(to: url)
        written += 1
        print("wrote \(v.file).json  (\(layout.items.count) portrait, \(layout.landscapeItems?.count ?? 0) landscape)")
    } catch {
        print("FAILED \(v.file): \(error)")
    }
}
print("\(written)/\(variants.count) written to \(outDir)")
