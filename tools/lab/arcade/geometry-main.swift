import Foundation
import CoreGraphics

// Every panel shape the arcade builder can produce, measured as a person
// would meet it: real points on a real phone, drawn silhouettes rather
// than bounding boxes, and touch resolved the way TouchControlPad
// actually resolves it.
//
// Two rules, and they are deliberately different, because drawing and
// hit testing are different. Buttons are drawn as circles, so two frames
// meeting at the corner are not an overlap and reporting one is noise.
// Hit testing is rectangular, so two hit frames meeting at the corner IS
// a place where the wrong control wins. Getting this backwards produced
// 937 imaginary findings before it produced a real one.
//
// Button against button is not reported: inputs(at:) already resolves
// that by nearest centre, one winner, on purpose. Analog kinds are the
// problem, because touchesBegan gives them the touch and stops.

struct Shape { let name: String; let json: String; let joystick: Bool }
let shapes: [Shape] = [
    Shape(name: "plain stick", json: "", joystick: true),
    Shape(name: "stick beside", json: #"{"stick":1}"#, joystick: true),
    Shape(name: "dial", json: #"{"dial":1}"#, joystick: false),
    Shape(name: "dial + stick", json: #"{"dial":1}"#, joystick: true),
    Shape(name: "dial + pedals", json: #"{"dial":1,"pedals":2}"#, joystick: false),
    Shape(name: "trackball", json: #"{"trackball":1}"#, joystick: false),
    Shape(name: "trackball + stick", json: #"{"trackball":1}"#, joystick: true),
    Shape(name: "paddle", json: #"{"paddle":1}"#, joystick: false),
    Shape(name: "paddle + pedals", json: #"{"paddle":1,"pedals":2}"#, joystick: false),
    Shape(name: "axis", json: #"{"axis":1}"#, joystick: true),
    Shape(name: "axis + pedals", json: #"{"axis":1,"pedals":2}"#, joystick: true),
    Shape(name: "rotary", json: #"{"rotary":1}"#, joystick: false),
    Shape(name: "lightgun", json: #"{"lightgun":1}"#, joystick: false),
]

func covers(_ item: ControlLayout.Item, _ p: CGPoint, in size: CGSize) -> Bool {
    let r = item.frame.resolved(in: size)
    guard r.contains(p) else { return false }
    switch item.kind {
    case .button, .stick, .spinner, .trackball, .rotary, .wheel:
        let dx = (p.x - r.midX) / (r.width / 2), dy = (p.y - r.midY) / (r.height / 2)
        return dx * dx + dy * dy <= 1
    case .pill, .pedal:
        let radius = min(r.width, r.height) / 2
        let cx = min(max(p.x, r.minX + radius), r.maxX - radius)
        let cy = min(max(p.y, r.minY + radius), r.maxY - radius)
        return hypot(p.x - cx, p.y - cy) <= radius
    case .dpad, .gun:
        return true
    }
}

func drawnOverlap(_ a: ControlLayout.Item, _ b: ControlLayout.Item, in size: CGSize) -> Int {
    let box = a.frame.resolved(in: size).intersection(b.frame.resolved(in: size))
    guard !box.isNull, box.width > 0, box.height > 0 else { return 0 }
    var n = 0, y = box.minY
    while y < box.maxY {
        var x = box.minX
        while x < box.maxX {
            let p = CGPoint(x: x, y: y)
            if covers(a, p, in: size) && covers(b, p, in: size) { n += 1 }
            x += 1
        }
        y += 1
    }
    return n
}

func name(_ i: ControlLayout.Item) -> String { "\(i.kind)\(i.label.map { " \($0)" } ?? "")" }

let analogKinds: Set<ControlLayout.Item.Kind> = [.stick, .spinner, .rotary, .wheel, .gun, .trackball]
var drawn: [String] = [], swallow: [String] = []

for shape in shapes {
    for buttons in 0...6 {
        var analog: AnalogControls?
        if !shape.json.isEmpty {
            analog = try? JSONDecoder().decode(AnalogControls.self, from: Data(shape.json.utf8))
        }
        let profile = ArcadeProfile(profile: shape.joystick ? "six_button" : "special",
                                    buttons: buttons, ways: "8", coins: 1, parent: nil, vertical: false)
        let layout = ArcadeLayout.build(for: profile, analog: analog)
        for landscape in [false, true] {
            let size = landscape ? CGSize(width: 844, height: 390) : CGSize(width: 390, height: 330)
            let items = layout.items(landscape: landscape)
            let at = "\(shape.name)/\(buttons)btn/\(landscape ? "landscape" : "portrait")"
            for (i, item) in items.enumerated() {
                for other in items[(i + 1)...] {
                    if item.kind == .dpad || other.kind == .dpad { continue }
                    // A gun's surface is the whole picture by design.
                    if item.kind == .gun || other.kind == .gun { continue }
                    let bite = drawnOverlap(item, other, in: size)
                    if bite >= 40 {
                        drawn.append("\(at): \(name(item)) and \(name(other)) overlap by \(bite)pt2")
                    }
                    let a = analogKinds.contains(item.kind), b = analogKinds.contains(other.kind)
                    guard a || b else { continue }
                    let hit = item.extended.resolved(in: size).intersection(other.extended.resolved(in: size))
                    if !hit.isNull, hit.width * hit.height >= 200 {
                        let eater = a ? item : other, eaten = a ? other : item
                        swallow.append("\(at): \(name(eater)) takes \(Int(hit.width * hit.height))pt2 of touches meant for \(name(eaten))")
                    }
                }
            }
        }
    }
}

print("panel geometry: \(shapes.count) shapes, 0 to 6 buttons, both orientations")
print("  drawn overlaps: \(drawn.count)")
for d in drawn { print("    " + d) }
print("  touches claimed by the wrong control: \(swallow.count)")
for s in swallow { print("    " + s) }
if drawn.isEmpty && swallow.isEmpty { print("  clean") }
exit(drawn.isEmpty && swallow.isEmpty ? 0 : 1)
