import CoreGraphics
import Foundation

/// A mutable mirror of `ControlLayout`, which is decode only by design.
///
/// Loading goes through `JSONSerialization` rather than `ControlLayout`'s own
/// decoder for one reason: `_ergonomics` carries the note explaining why a
/// layout is shaped the way it is, the decoder ignores it, and an editor that
/// round trips a file has to hand back everything it was given. Every key in
/// every bundled layout is accounted for here, so nothing is silently dropped.
struct EditableLayout {
    /// The bundled file's base name, which is the identity used everywhere:
    /// a layout is a file, and the file name is what gets replaced.
    let name: String
    var system: String
    var ergonomics: String?
    /// Extra portrait strip height, as a fraction of the strip, mirrored
    /// from `ControlLayout.headroom`. Nil round trips as nil rather than
    /// zero, so a layout that never asked for headroom does not gain a
    /// spurious `_headroom: 0` line the first time it is opened here.
    var headroom: Double?
    var items: [EditableItem]
    /// Nil when the file never carried a landscape set. The player falls back
    /// to portrait items in that case, which works but looks wrong, so the
    /// editor says so rather than quietly editing the portrait set twice.
    var landscapeItems: [EditableItem]?

    func items(landscape: Bool) -> [EditableItem] {
        guard landscape, let wide = landscapeItems, !wide.isEmpty else { return items }
        return wide
    }
}

struct EditableItem: Identifiable {
    let id = UUID()
    var kind: ControlLayout.Item.Kind
    var label: String?
    var input: Int?
    var inputs: [Int]?
    var frame: EditRect
    var extended: EditRect
    var fourWay: Bool?

    /// What the pad draws for this item. Built through `ControlLayout.Item`'s
    /// own initialiser so the editor can never render something the player
    /// could not: if the schema gains a field, this stops compiling.
    var rendered: ControlLayout.Item {
        ControlLayout.Item(
            kind: kind, label: label, input: input, inputs: inputs,
            frame: frame.rendered, extended: extended.rendered, fourWay: fourWay
        )
    }

    /// How far the hit tested frame extends past the drawn one on each side.
    /// Moving or resizing preserves these, because the gap between the two
    /// rects is the whole reason touch controls feel forgiving, and having to
    /// repair it by hand after every drag would defeat the point of the tool.
    var padding: (left: Double, top: Double, right: Double, bottom: Double) {
        (
            left: frame.x - extended.x,
            top: frame.y - extended.y,
            right: extended.maxX - frame.maxX,
            bottom: extended.maxY - frame.maxY
        )
    }

    /// Rebuilds `extended` around the current `frame` from the padding given.
    mutating func applyPadding(_ pad: (left: Double, top: Double, right: Double, bottom: Double)) {
        extended = EditRect(
            x: frame.x - pad.left,
            y: frame.y - pad.top,
            w: frame.w + pad.left + pad.right,
            h: frame.h + pad.top + pad.bottom
        )
    }

    /// A short human name for the inspector: the label where there is one,
    /// the kind where there is not.
    var displayName: String {
        if let label, !label.isEmpty { return label }
        return kind.rawValue.capitalized
    }
}

/// Normalised 0 to 1, exactly as the layout files store it, against whatever
/// the host hands the pad: the bottom strip in portrait, the full screen in
/// landscape.
struct EditRect: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }

    var rendered: ControlLayout.Rect { ControlLayout.Rect(x: x, y: y, w: w, h: h) }

    func resolved(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height)
    }

    func offset(dx: Double, dy: Double) -> EditRect {
        EditRect(x: x + dx, y: y + dy, w: w, h: h)
    }

    func intersects(_ other: EditRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }
}

// MARK: Loading

extension EditableLayout {
    /// Every layout the editor can open, which is every layout the app bundles:
    /// both targets take the same files from the same folder.
    static func allNames() -> [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// Loads a layout, preferring an in progress working copy over the bundled
    /// file. Edits survive the app being killed, which matters when the whole
    /// point is long fiddly sessions of moving things a few points at a time.
    static func load(_ name: String) -> EditableLayout? {
        let working = WorkingCopy.url(for: name)
        if FileManager.default.fileExists(atPath: working.path),
           let data = try? Data(contentsOf: working),
           let layout = decode(data, name: name) {
            return layout
        }
        return loadBundled(name)
    }

    static func loadBundled(_ name: String) -> EditableLayout? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return decode(data, name: name)
    }

    private static func decode(_ data: Data, name: String) -> EditableLayout? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let system = root["system"] as? String
        else { return nil }
        return EditableLayout(
            name: name,
            system: system,
            ergonomics: root["_ergonomics"] as? String,
            headroom: root["_headroom"] as? Double,
            items: decodeItems(root["items"]) ?? [],
            landscapeItems: decodeItems(root["landscapeItems"])
        )
    }

    private static func decodeItems(_ raw: Any?) -> [EditableItem]? {
        guard let array = raw as? [[String: Any]] else { return nil }
        return array.compactMap { entry in
            guard let kindRaw = entry["kind"] as? String,
                  let kind = ControlLayout.Item.Kind(rawValue: kindRaw),
                  let frame = decodeRect(entry["frame"]),
                  let extended = decodeRect(entry["extended"])
            else { return nil }
            return EditableItem(
                kind: kind,
                label: entry["label"] as? String,
                input: entry["input"] as? Int,
                inputs: entry["inputs"] as? [Int],
                frame: frame,
                extended: extended,
                fourWay: entry["fourWay"] as? Bool
            )
        }
    }

    private static func decodeRect(_ raw: Any?) -> EditRect? {
        guard let d = raw as? [String: Any],
              let x = d["x"] as? Double, let y = d["y"] as? Double,
              let w = d["w"] as? Double, let h = d["h"] as? Double
        else { return nil }
        return EditRect(x: x, y: y, w: w, h: h)
    }
}

// MARK: Emitting

extension EditableLayout {
    /// The layout as JSON, in the shape the bundled files already use: one
    /// space per level, rects and id lists on a single line, keys in the
    /// order a reader expects rather than alphabetical.
    ///
    /// Matching the existing formatting is not fussiness. These files get
    /// reviewed as diffs, and an exporter that reflowed every line would bury
    /// a two number change in a whole file rewrite. It also quietly repairs
    /// the files an earlier pass left expanded, and the float drift that came
    /// with them (`0.020000000000000004` in psx.json).
    func jsonText() -> String {
        var out = "{\n"
        out += " \"system\": \(Self.quote(system)),\n"
        if let ergonomics {
            out += " \"_ergonomics\": \(Self.quote(ergonomics)),\n"
        }
        if let headroom {
            out += " \"_headroom\": \(Self.number(headroom)),\n"
        }
        out += " \"items\": \(Self.emit(items, indent: 1))"
        if let landscapeItems {
            out += ",\n \"landscapeItems\": \(Self.emit(landscapeItems, indent: 1))"
        }
        out += "\n}\n"
        return out
    }

    private static func emit(_ items: [EditableItem], indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = pad + " "
        let field = inner + " "
        guard !items.isEmpty else { return "[]" }
        var out = "[\n"
        out += items.map { item -> String in
            var lines: [String] = ["\(field)\"kind\": \(quote(item.kind.rawValue))"]
            if let label = item.label { lines.append("\(field)\"label\": \(quote(label))") }
            if let input = item.input { lines.append("\(field)\"input\": \(input)") }
            if let inputs = item.inputs {
                lines.append("\(field)\"inputs\": [\(inputs.map(String.init).joined(separator: ", "))]")
            }
            lines.append("\(field)\"frame\": \(rect(item.frame))")
            lines.append("\(field)\"extended\": \(rect(item.extended))")
            if let fourWay = item.fourWay { lines.append("\(field)\"fourWay\": \(fourWay)") }
            return "\(inner){\n" + lines.joined(separator: ",\n") + "\n\(inner)}"
        }.joined(separator: ",\n")
        out += "\n\(pad)]"
        return out
    }

    private static func rect(_ r: EditRect) -> String {
        "{\"x\": \(number(r.x)), \"y\": \(number(r.y)), \"w\": \(number(r.w)), \"h\": \(number(r.h))}"
    }

    /// Shortest faithful spelling of a grid snapped value: 0.4 not 0.4000,
    /// and 0.0 rather than a bare 0, which is how the files already read.
    static func number(_ v: Double) -> String {
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s += "0" }
        return s
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }
}

// MARK: Working copies and export

enum WorkingCopy {
    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var folder: URL {
        let url = documents.appendingPathComponent("Working", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(for name: String) -> URL {
        folder.appendingPathComponent("\(name).json")
    }

    static func save(_ layout: EditableLayout) {
        try? layout.jsonText().data(using: .utf8)?.write(to: url(for: layout.name))
    }

    static func discard(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
        setReady(name, false)
    }

    static func isEdited(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    /// The signal for "come get this one." A zero byte marker rather than
    /// anything in the JSON itself: readiness is a fact about the working
    /// copy, not part of the layout, and a marker file is something a plain
    /// `find` across the pulled container can pick out without parsing
    /// anything, no app-side network call, no listener on the Mac. The whole
    /// mechanism is: you flag it here, later someone (a person, on the Mac
    /// side) goes looking for flags.
    private static func readyURL(for name: String) -> URL {
        folder.appendingPathComponent("\(name).ready")
    }

    static func isReady(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: readyURL(for: name).path)
    }

    static func setReady(_ name: String, _ ready: Bool) {
        if ready {
            FileManager.default.createFile(atPath: readyURL(for: name).path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: readyURL(for: name))
        }
    }

    /// A copy under its real file name, ready to hand to the share sheet and
    /// drop straight into Resources/ControlLayouts.
    static func exportFile(_ layout: EditableLayout) -> URL? {
        let folder = documents.appendingPathComponent("Export", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(layout.name).json")
        guard let data = layout.jsonText().data(using: .utf8) else { return nil }
        try? data.write(to: url)
        return url
    }
}
