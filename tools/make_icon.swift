// Renders Cabinet's app icon.
//
//   swift tools/make_icon.swift <output.png>
//
// Kept as a generator rather than a checked in binary so the icon can be
// adjusted by editing numbers instead of opening a drawing program.
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

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

func rounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}

// Backdrop: a dark arcade room, lit from above. The gradient keeps the icon
// from reading as a flat sticker at large sizes.
let backdrop = CGGradient(
    colorsSpace: space,
    colors: [rgb(58, 34, 104), rgb(18, 12, 38), rgb(9, 6, 20)] as CFArray,
    locations: [0, 0.55, 1]
)!
ctx.drawLinearGradient(
    backdrop,
    start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 0), options: []
)

// The cabinet body. A real cabinet has a tall empty lower half, but at icon
// sizes that dead space just makes the shape bottom heavy, so the body is
// cropped short of accurate proportions on purpose.
ctx.setFillColor(rgb(238, 234, 226))
ctx.addPath(rounded(268, 206, 488, 684, 56))
ctx.fillPath()

// Marquee: the lit sign across the top of every upright cabinet.
let marquee = CGGradient(
    colorsSpace: space,
    colors: [rgb(255, 122, 199), rgb(255, 196, 87)] as CFArray,
    locations: [0, 1]
)!
ctx.saveGState()
ctx.addPath(rounded(316, 762, 392, 84, 20))
ctx.clip()
ctx.drawLinearGradient(
    marquee,
    start: CGPoint(x: 316, y: 0), end: CGPoint(x: 708, y: 0), options: []
)
ctx.restoreGState()

// The screen, the brightest thing in the icon so the eye lands there first.
ctx.saveGState()
ctx.addPath(rounded(316, 446, 392, 284, 24))
ctx.clip()
let screen = CGGradient(
    colorsSpace: space,
    colors: [rgb(88, 232, 246), rgb(36, 132, 214)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    screen,
    start: CGPoint(x: 0, y: 730), end: CGPoint(x: 0, y: 446), options: []
)
// A soft glow across the top of the glass. A hard edged band read as a seam
// rather than a reflection, so this fades out instead.
let sheen = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.26),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    sheen,
    start: CGPoint(x: 0, y: 730), end: CGPoint(x: 0, y: 590), options: []
)
ctx.restoreGState()

// Control panel, stepped out from the body the way a real one overhangs.
ctx.setFillColor(rgb(206, 199, 188))
ctx.addPath(rounded(248, 312, 528, 112, 26))
ctx.fillPath()

// A joystick and two buttons: the smallest arrangement that still says arcade
// rather than television.
ctx.setFillColor(rgb(58, 52, 68))
ctx.fillEllipse(in: CGRect(x: 320, y: 340, width: 56, height: 56))
ctx.setFillColor(rgb(236, 64, 92))
ctx.fillEllipse(in: CGRect(x: 474, y: 344, width: 50, height: 50))
ctx.setFillColor(rgb(255, 196, 87))
ctx.fillEllipse(in: CGRect(x: 558, y: 344, width: 50, height: 50))

// Base, narrower than the body so the cabinet sits rather than floats.
ctx.setFillColor(rgb(206, 199, 188))
ctx.addPath(rounded(302, 172, 420, 58, 18))
ctx.fillPath()

guard let image = ctx.makeImage() else { fatalError("could not render") }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let url = URL(fileURLWithPath: out)
guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("could not open \(out)") }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
