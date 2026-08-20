// Proves the bundled arcade layout files still reproduce the generator.
//
// The player prefers these files over ArcadeLayout's generated
// arrangement, so a file that drifts from the generator silently moves
// every arcade game's controls. This compares them item by item and
// reports the largest difference in normalised units; the generator is
// unreachable from the app once a file exists, so this is the only thing
// standing between a bad export and fourteen wrong layouts.
//
// Run: sh tools/lab/arcade/verify.sh
// Expected after a fresh dump: every variant within the exporter's own
// 4-decimal rounding (1e-4), which is a hundredth of a point on screen.

import Foundation

let dir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

var failures = 0
var worst = 0.0
var worstWhere = ""

func rects(_ i: ControlLayout.Item) -> [(String, ControlLayout.Rect)] {
    [("frame", i.frame), ("extended", i.extended)]
}

func compare(_ generated: [ControlLayout.Item], _ loaded: [[String: Any]], label: String, file: String) {
    guard generated.count == loaded.count else {
        print("FAIL \(file) \(label): \(generated.count) generated vs \(loaded.count) in file")
        failures += 1
        return
    }
    for (index, gen) in generated.enumerated() {
        let got = loaded[index]
        if gen.kind.rawValue != (got["kind"] as? String) {
            print("FAIL \(file) \(label)[\(index)]: kind \(gen.kind.rawValue) vs \(got["kind"] ?? "nil")")
            failures += 1
            continue
        }
        if gen.label != got["label"] as? String {
            print("FAIL \(file) \(label)[\(index)]: label \(gen.label ?? "nil") vs \(got["label"] ?? "nil")")
            failures += 1
        }
        if gen.input != got["input"] as? Int {
            print("FAIL \(file) \(label)[\(index)]: input \(gen.input.map(String.init) ?? "nil") vs \(got["input"] ?? "nil")")
            failures += 1
        }
        if gen.inputs ?? [] != got["inputs"] as? [Int] ?? [] {
            print("FAIL \(file) \(label)[\(index)]: inputs differ")
            failures += 1
        }
        for (name, r) in rects(gen) {
            guard let gotRect = got[name] as? [String: Double] else {
                print("FAIL \(file) \(label)[\(index)]: missing \(name)")
                failures += 1
                continue
            }
            for (axis, value) in [("x", r.x), ("y", r.y), ("w", r.w), ("h", r.h)] {
                let delta = abs((gotRect[axis] ?? .nan) - value)
                if delta > worst {
                    worst = delta
                    worstWhere = "\(file) \(label)[\(index)].\(name).\(axis)"
                }
                if delta > 1e-4 {
                    print("FAIL \(file) \(label)[\(index)].\(name).\(axis): file \(gotRect[axis] ?? .nan) vs generated \(value)")
                    failures += 1
                }
            }
        }
    }
}

for dual in [false, true] {
    for n in 0...6 {
        let file = "arcade-\(dual ? "twin" : "stick")\(n)"
        let profile = ArcadeProfile(
            profile: dual ? "dual_stick" : "six_button",
            buttons: n, ways: "8", coins: 1, parent: nil, vertical: false
        )
        // No bundle here, so build() finds no tuned file and returns the
        // raw generated arrangement, which is exactly what we compare to.
        let generated = ArcadeLayout.build(for: profile)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(file).json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            print("FAIL \(file): missing or unreadable")
            failures += 1
            continue
        }
        compare(generated.items, root["items"] as? [[String: Any]] ?? [],
                label: "portrait", file: file)
        compare(generated.landscapeItems ?? [], root["landscapeItems"] as? [[String: Any]] ?? [],
                label: "landscape", file: file)
    }
}

print(String(format: "worst drift %.6f at %@", worst, worstWhere.isEmpty ? "nowhere" : worstWhere))
print(failures == 0 ? "ARCADE LAYOUTS MATCH THE GENERATOR" : "\(failures) MISMATCHES")
exit(failures == 0 ? 0 : 1)
