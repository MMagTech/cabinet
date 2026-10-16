// Renders Cabinet Go's app icon.
//
//   swift tools/make_icon_go.swift <output.png>
//
// Cabinet Go is the handheld half of CabinetOS (docs/scope-handheld.md),
// so its icon is Cabinet's arcade cabinet turned into a pocket console in
// the same language: the same night sky, the cream body, the marquee's
// pink to gold across the top, the cyan screen, a dark control and the
// red and yellow buttons. When the app becomes Cabinet Go this replaces
// tools/make_icon.swift and its output replaces icon-1024.png.
//
// The Game Boy's own signatures are left out on purpose: one oversized
// corner, a dark bezel carrying a stripe, and the two angled pills under
// the buttons. Nintendo guards that look, and App Review is wary of an
// emulator whose artwork resembles its hardware. Even corners, the
// marquee on the body and a bezel in the cabinet's panel colour keep it a
// generic handheld. A d-pad with two angled buttons is every handheld's.
//
// Follows Apple's icon rules: a single 1024 square, fully opaque, square
// cornered because the system applies its own mask, no text, and a shape
// simple enough to survive being drawn at 40 points on a home screen.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let space = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil, width: side, height: side,
    bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("could not create context") }

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func rounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}

func fill(_ path: CGPath, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(path)
    ctx.fillPath()
}

func dot(_ cx: Double, _ cy: Double, _ d: Double, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
}

// Backdrop: Cabinet's dark arcade room, lit from above, unchanged so the
// two icons sit together on a home screen.
let backdrop = CGGradient(
    colorsSpace: space,
    colors: [rgb(58, 34, 104), rgb(18, 12, 38), rgb(9, 6, 20)] as CFArray,
    locations: [0, 0.55, 1]
)!
ctx.drawLinearGradient(
    backdrop,
    start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 0), options: []
)

// The body, upright, with the same corner all round.
fill(rounded(292, 150, 440, 740, 72), rgb(238, 234, 226))

// The marquee, kept from the cabinet: the lit sign is the family resemblance.
let marquee = CGGradient(
    colorsSpace: space,
    colors: [rgb(255, 122, 199), rgb(255, 196, 87)] as CFArray,
    locations: [0, 1]
)!
ctx.saveGState()
ctx.addPath(rounded(340, 810, 344, 40, 20))
ctx.clip()
ctx.drawLinearGradient(
    marquee,
    start: CGPoint(x: 340, y: 0), end: CGPoint(x: 684, y: 0), options: []
)
ctx.restoreGState()

// The bezel, in the cabinet's control panel colour rather than a dark frame.
fill(rounded(340, 470, 344, 316, 30), rgb(206, 199, 188))

// The screen, still the brightest thing in the icon, with the same soft
// glow across the top of the glass as Cabinet's.
ctx.saveGState()
ctx.addPath(rounded(362, 492, 300, 272, 18))
ctx.clip()
let screen = CGGradient(
    colorsSpace: space,
    colors: [rgb(88, 232, 246), rgb(36, 132, 214)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    screen,
    start: CGPoint(x: 0, y: 764), end: CGPoint(x: 0, y: 492), options: []
)
let sheen = CGGradient(
    colorsSpace: space,
    colors: [rgb(255, 255, 255, 0.26), rgb(255, 255, 255, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    sheen,
    start: CGPoint(x: 0, y: 764), end: CGPoint(x: 0, y: 628), options: []
)
ctx.restoreGState()

// The d-pad, in the joystick's colour.
let ink = rgb(58, 52, 68)
fill(rounded(404 - 74, 318 - 25, 148, 50, 11), ink)
fill(rounded(404 - 25, 318 - 74, 50, 148, 11), ink)

// The arcade's two buttons, angled the way a handheld's are: red low on
// the left, yellow high on the right.
dot(578, 294, 64, rgb(236, 64, 92))
dot(652, 344, 64, rgb(255, 196, 87))

guard let image = ctx.makeImage() else { fatalError("could not render") }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let url = URL(fileURLWithPath: out)
guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("could not open \(out)") }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
