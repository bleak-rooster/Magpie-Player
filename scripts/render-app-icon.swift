// Renders the app icon (docs/storyboard/canvas/Brand-Magpie.dc.html, "App icon"): a record slipping out of
// its sleeve, in the light, dark and tinted variants, as 1024 × 1024 opaque PNGs into the asset catalog.
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift scripts/render-app-icon.swift
// Geometry is the brand sheet's 100 × 100 SVG viewBox, scaled.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Palette {
    var background: UInt32
    var record: (UInt32, CGFloat)
    var groove: (UInt32, CGFloat)
    var label: (UInt32, CGFloat)
    var spindle: UInt32
    var sleeve: (UInt32, CGFloat)
    var stripe: (UInt32, CGFloat)
}

let variants: [(file: String, palette: Palette)] = [
    ("AppIcon.png", Palette(background: 0xF4EFE6, record: (0x1B1A19, 1), groove: (0x2C2A28, 1), label: (0x3CC4B8, 1),
                            spindle: 0xF4EFE6, sleeve: (0x16130F, 1), stripe: (0x3CC4B8, 1))),
    ("AppIcon-Dark.png", Palette(background: 0x16130F, record: (0x2E2A26, 1), groove: (0x3A3632, 1), label: (0x3CC4B8, 1),
                                 spindle: 0x16130F, sleeve: (0xF4F1EA, 1), stripe: (0x3CC4B8, 1))),
    ("AppIcon-Tinted.png", Palette(background: 0x151517, record: (0xF0F0F5, 0.22), groove: (0xF0F0F5, 0.30),
                                   label: (0xF0F0F5, 0.62), spindle: 0x151517, sleeve: (0xF0F0F5, 0.92),
                                   stripe: (0x151517, 0.55))),
]

func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
}

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
              : "App/Resources/Assets.xcassets/AppIcon.appiconset")

for (file, p) in variants {
    // No alpha channel: App Store icons must be opaque.
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("context") }
    // SVG coordinates: origin top-left, 100 units across.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(size) / 100, y: -CGFloat(size) / 100)

    ctx.setFillColor(color(p.background))
    ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))

    func circle(_ r: CGFloat) -> CGRect { CGRect(x: 62 - r, y: 50 - r, width: 2 * r, height: 2 * r) }
    ctx.setFillColor(color(p.record.0, p.record.1))
    ctx.fillEllipse(in: circle(30))
    ctx.setStrokeColor(color(p.groove.0, p.groove.1))
    ctx.setLineWidth(1)
    for r: CGFloat in [27, 24, 21, 18, 15] { ctx.strokeEllipse(in: circle(r)) }
    ctx.setFillColor(color(p.label.0, p.label.1))
    ctx.fillEllipse(in: circle(10.2))
    ctx.setFillColor(color(p.spindle))
    ctx.fillEllipse(in: circle(1.8))

    ctx.setFillColor(color(p.sleeve.0, p.sleeve.1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 12, y: 22, width: 56, height: 56), cornerWidth: 6.7, cornerHeight: 6.7,
                       transform: nil))
    ctx.fillPath()
    ctx.setFillColor(color(p.stripe.0, p.stripe.1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 22, y: 64.6, width: 36, height: 3.4), cornerWidth: 1, cornerHeight: 1,
                       transform: nil))
    ctx.fillPath()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(out.appending(path: file) as CFURL, UTType.png.identifier as CFString,
                                                     1, nil) else { fatalError("image \(file)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("write \(file)") }
    print("wrote \(out.appending(path: file).path)")
}
