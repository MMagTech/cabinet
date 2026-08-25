// Exports one layout file per ANALOG arcade panel shape, and proves the
// naming is one to one before it writes anything.
//
// The sibling main.swift does this for plain stick and twin-stick
// cabinets. This does the rest: dial, trackball, rotary, light gun and
// pedal panels, which between them are most of the cabinets anyone would
// call memorable and, until this existed, the ones that could not be
// tuned at all.
//
// The naming rule lives in ArcadeLayout.tunedPanelName and is CALLED here
// rather than restated, because the last version of this idea had the
// rule written twice and the two copies disagreed: files sat in the
// bundle under names the app never asked for.
//
// The proof matters more than the export. Two cabinets that resolve to
// the same file must generate the same layout, or that file is wrong for
// one of them, which is exactly how a two pedal panel would have landed
// on a one pedal machine. This asserts that over every romset in the
// data and refuses to write if it fails.
//
// Run: sh tools/lab/arcade/panels.sh

import Foundation

let args = CommandLine.arguments
guard args.count > 4 else {
    print("usage: panels-main <outDir> <profiles.json> <arcade-panels.json> <analog-controls.json>")
    exit(2)
}
let outDir = args[1]

func loadJSON(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        print("cannot read \(path)"); exit(1)
    }
    return obj
}

let profileRows = loadJSON(args[2])
let curatedRows = loadJSON(args[3])
let generatedRows = loadJSON(args[4])

func analog(for name: String) -> AnalogControls? {
    // Same precedence the app uses: a curated cabinet fact beats the
    // generated inference, always.
    let raw = (curatedRows[name] as? [String: Int]) ?? (generatedRows[name] as? [String: Int])
    guard let raw,
          let data = try? JSONSerialization.data(withJSONObject: raw),
          let decoded = try? JSONDecoder().decode(AnalogControls.self, from: data)
    else { return nil }
    return decoded
}

func profile(for row: [Any]) -> ArcadeProfile {
    ArcadeProfile(
        profile: row.first as? String ?? "six_button",
        buttons: row.count > 1 ? (row[1] as? Int ?? 0) : 0,
        ways: row.count > 2 ? (row[2] as? String ?? "") : "",
        coins: row.count > 3 ? (row[3] as? Int ?? 0) : 0,
        parent: row.count > 4 ? (row[4] as? String) : nil,
        vertical: row.count > 5 ? (row[5] as? Int ?? 0) == 1 : false
    )
}

func rect(_ r: ControlLayout.Rect) -> EditRect { EditRect(x: r.x, y: r.y, w: r.w, h: r.h) }
func item(_ i: ControlLayout.Item) -> EditableItem {
    EditableItem(
        kind: i.kind, label: i.label, input: i.input, inputs: i.inputs,
        frame: rect(i.frame), extended: rect(i.extended), fourWay: i.fourWay)
}

/// A layout flattened to a comparable string, so "did these two cabinets
/// produce the same panel" is one equality rather than a walk.
func fingerprint(_ layout: ControlLayout) -> String {
    func one(_ items: [ControlLayout.Item]) -> String {
        items.map { i in
            let f = i.frame, e = i.extended
            return [
                i.kind.rawValue, i.label ?? "-", i.input.map(String.init) ?? "-",
                (i.inputs ?? []).map(String.init).joined(separator: ","),
                String(format: "%.4f,%.4f,%.4f,%.4f", f.x, f.y, f.w, f.h),
                String(format: "%.4f,%.4f,%.4f,%.4f", e.x, e.y, e.w, e.h),
                i.fourWay.map(String.init) ?? "-",
            ].joined(separator: "|")
        }.joined(separator: ";")
    }
    return one(layout.items) + "//" + one(layout.landscapeItems ?? [])
}

struct Shape {
    let profile: ArcadeProfile
    let analog: AnalogControls
    let layout: ControlLayout
    let print: String
    var examples: [String] = []
}

var shapes: [String: Shape] = [:]
var collisions = 0
var considered = 0

for (romset, value) in profileRows {
    guard let row = value as? [Any], let controls = analog(for: romset) else { continue }
    let prof = profile(for: row)
    guard let name = ArcadeLayout.tunedPanelName(for: prof, analog: controls) else { continue }
    considered += 1
    let layout = ArcadeLayout.build(for: prof, analog: controls)
    let mark = fingerprint(layout)
    if var existing = shapes[name] {
        if existing.print != mark {
            print("COLLISION \(name): \(existing.examples.first ?? "?") and \(romset) share a name but not a panel")
            collisions += 1
        }
        if existing.examples.count < 4 { existing.examples.append(romset) }
        shapes[name] = existing
    } else {
        shapes[name] = Shape(
            profile: prof, analog: controls, layout: layout, print: mark, examples: [romset])
    }
}

print("\(considered) analog cabinets -> \(shapes.count) distinct panel files")
guard collisions == 0 else {
    print("\(collisions) collisions: the name does not describe the panel completely. Nothing written.")
    exit(1)
}

let ergonomics = """
Generated from ArcadeLayout for one analog panel shape, then tuned by \
hand. The mechanism takes the movement role and the stick's slot when the \
cabinet had no joystick, or its own lane beside a narrowed stick when it \
did. Pedals hold the right edge under a resting thumb. Coin, Start and \
Menu keep the top band. The file name states the whole panel: the \
mechanism, the button count, the pedal count and whether a stick was \
there too, because a file that matched a cabinet only approximately is \
how a brake once landed on a machine that never had one.
"""

var written = 0
for (name, shape) in shapes.sorted(by: { $0.key < $1.key }) {
    let editable = EditableLayout(
        name: name,
        system: shape.layout.system,
        ergonomics: ergonomics,
        headroom: shape.layout.headroom,
        items: shape.layout.items.map(item),
        landscapeItems: shape.layout.landscapeItems?.map(item)
    )
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).json")
    do {
        try editable.jsonText().data(using: .utf8)!.write(to: url)
        written += 1
        print("wrote \(name).json  (\(shape.examples.joined(separator: ", ")))")
    } catch {
        print("FAILED \(name): \(error)")
    }
}
print("\(written)/\(shapes.count) written to \(outDir)")
