// Renders the app icon: the storyboard's green "art-4" cover (Overview and Character dial,
// docs/storyboard/canvas/Main.dc.html, Compare-Character.dc.html), a forest-green diagonal field with a pale mint
// dome rising from the bottom centre (the beak). Light, dark and tinted variants, as 1024 x 1024 opaque PNGs into
// the asset catalog. Brand sheet: docs/storyboard/canvas/Brand-Magpie.dc.html, "App icon".
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift scripts/render-app-icon.swift [output-dir]
// art-4 CSS: radial-gradient(ellipse at 50% 110%, #B7E4C7 0 35%, transparent 36%), linear-gradient(135deg, #1B4332, #40916C)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

struct Variant {
    var file: String
    var fieldFrom: CGColor, fieldTo: CGColor
    var domeTop: CGColor, domeBottom: CGColor
    var glow: CGColor
}

let variants = [
    Variant(file: "AppIcon.png", fieldFrom: rgb(0x1B4332), fieldTo: rgb(0x40916C),
            domeTop: rgb(0xD8F3DC), domeBottom: rgb(0xB7E4C7), glow: rgb(0xB7E4C7, 0.22)),
    Variant(file: "AppIcon-Dark.png", fieldFrom: rgb(0x0B1F17), fieldTo: rgb(0x1B4332),
            domeTop: rgb(0xB7E4C7), domeBottom: rgb(0x74C69D), glow: rgb(0x74C69D, 0.18)),
    Variant(file: "AppIcon-Tinted.png", fieldFrom: rgb(0x151517), fieldTo: rgb(0x2A2A2E),
            domeTop: rgb(0xF0F0F5, 0.95), domeBottom: rgb(0xF0F0F5, 0.70), glow: rgb(0xF0F0F5, 0.10)),
]

let size = 1024
let s = CGFloat(size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
              : "App/Resources/Assets.xcassets/AppIcon.appiconset")

for v in variants {
    // No alpha channel: App Store icons must be opaque.
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("context") }
    // Top-left origin, like CSS.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    // Field: 135 degrees, top-left to bottom-right.
    let field = CGGradient(colorsSpace: space, colors: [v.fieldFrom, v.fieldTo] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(field, start: .zero, end: CGPoint(x: s, y: s), options: [])

    // Dome: ellipse centred at (50%, 110%), rx 26.5%, ry 58% of the side.
    let cx = s * 0.5, cy = s * 1.10, rx = s * 0.265, ry = s * 0.58
    let dome = CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry)

    // Soft glow behind the dome so it lifts off the field.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.06, color: v.glow)
    ctx.setFillColor(v.domeBottom)
    ctx.fillEllipse(in: dome)
    ctx.restoreGState()

    // Dome fill: gentle vertical gradient, lighter at the crown.
    ctx.saveGState()
    ctx.addEllipse(in: dome)
    ctx.clip()
    let domeGrad = CGGradient(colorsSpace: space, colors: [v.domeTop, v.domeBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(domeGrad, start: CGPoint(x: cx, y: cy - ry), end: CGPoint(x: cx, y: s), options: [])
    ctx.restoreGState()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(out.appending(path: v.file) as CFURL, UTType.png.identifier as CFString,
                                                     1, nil) else { fatalError("image \(v.file)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("write \(v.file)") }
    print("wrote \(out.appending(path: v.file).path)")
}
