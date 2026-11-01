// R14: renders Magpie's alternate app icons: 4 designs x 3 colourways, flat and matte, at most 3 colours each
// (no gradients, no gloss, no shadows). Writes, from the repo root:
//   - App/Resources/Assets.xcassets/<Name>.appiconset (1024 x 1024 opaque PNG + Contents.json) for each icon;
//   - App/Resources/Assets.xcassets/IconPreview-<Name>.imageset (180 px) for Settings › Appearance › App icon,
//     plus IconPreview-Default from the default AppIcon.png;
//   - docs/storyboard/app-icons-preview.png, the sheet for the owner (each icon large and at 60 px).
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift scripts/render-alternate-icons.swift
// Names must match AppIconChoice (App/Screens/Settings/AppIconChoice.swift) and project.yml's
// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/// The three colours of a colourway: a dark, a light and a pop.
struct Colourway { var name: String; var dark: CGColor; var light: CGColor; var pop: CGColor }

let colourways = [
    Colourway(name: "Forest", dark: rgb(0x1B4332), light: rgb(0xF1EBDD), pop: rgb(0x74C69D)),   // greens + cream
    Colourway(name: "Ink", dark: rgb(0x1D2A44), light: rgb(0xEFE8DA), pop: rgb(0xF07167)),      // navy + bone + coral
    Colourway(name: "Sunset", dark: rgb(0x2B2A29), light: rgb(0xEAD2AC), pop: rgb(0xC4532D)),   // charcoal + sand + rust
]

let side = 1024
let s = CGFloat(side)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func canvas(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // top-left origin
    return ctx
}

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
func circle(_ ctx: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: CGColor) {
    ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: (cx - r) * s, y: (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
}
func polygon(_ ctx: CGContext, _ pts: [CGPoint], _ c: CGColor) {
    ctx.setFillColor(c); ctx.beginPath(); ctx.addLines(between: pts); ctx.closePath(); ctx.fillPath()
}
/// An ellipse centred at (cx, cy), rotated by `deg`.
func ellipsePath(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ deg: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: cx * s, y: cy * s).rotated(by: deg * .pi / 180)
    return CGPath(ellipseIn: CGRect(x: -rx * s, y: -ry * s, width: 2 * rx * s, height: 2 * ry * s), transform: &t)
}

// MARK: Designs

/// 1. Record: a dark disc on a light field; its label is the pop colour, shaped as a magpie's head: the spindle hole
/// is the eye and a dark beak points out.
func record(_ ctx: CGContext, _ c: Colourway) {
    ctx.setFillColor(c.light); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    circle(ctx, 0.5, 0.5, 0.40, c.dark)
    ctx.setStrokeColor(c.light); ctx.setLineWidth(0.012 * s)
    for r: CGFloat in [0.335, 0.285] {
        ctx.strokeEllipse(in: CGRect(x: (0.5 - r) * s, y: (0.5 - r) * s, width: 2 * r * s, height: 2 * r * s))
    }
    circle(ctx, 0.5, 0.5, 0.18, c.pop)
    polygon(ctx, [p(0.55, 0.435), p(0.765, 0.5), p(0.55, 0.565)], c.dark)     // the beak, over the label's edge
    circle(ctx, 0.465, 0.5, 0.037, c.light)                                    // spindle hole / eye
}

/// 2. Magpie: a geometric magpie, dark, with its light belly and shoulder, perched on a pop field.
func magpie(_ ctx: CGContext, _ c: Colourway) {
    ctx.setFillColor(c.pop); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    // Legs: two short strokes, drawn first so the body covers their tops.
    ctx.setStrokeColor(c.dark); ctx.setLineWidth(0.024 * s); ctx.setLineCap(.round)
    for x: CGFloat in [0.54, 0.61] {
        ctx.beginPath(); ctx.move(to: p(x, 0.6)); ctx.addLine(to: p(x - 0.02, 0.81)); ctx.strokePath()
    }
    // Tail: a long blade down to the left.
    polygon(ctx, [p(0.36, 0.56), p(0.44, 0.66), p(0.17, 0.89), p(0.11, 0.83)], c.dark)
    // Body and head.
    let body = ellipsePath(0.5, 0.55, 0.215, 0.145, -28)
    ctx.addPath(body); ctx.setFillColor(c.dark); ctx.fillPath()
    circle(ctx, 0.665, 0.355, 0.105, c.dark)
    // Beak.
    polygon(ctx, [p(0.745, 0.315), p(0.875, 0.36), p(0.75, 0.395)], c.dark)
    // Belly and shoulder, kept inside the body.
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    ctx.addPath(ellipsePath(0.585, 0.64, 0.16, 0.085, -28)); ctx.setFillColor(c.light); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(ellipsePath(0.43, 0.53, 0.105, 0.04, -28)); ctx.setFillColor(c.light); ctx.fillPath()
    // Eye.
    circle(ctx, 0.69, 0.335, 0.022, c.light)
}

/// 3. Wave: an "M" drawn as one sound-wave stroke, light on dark, with pop level bars either side.
func wave(_ ctx: CGContext, _ c: Colourway) {
    ctx.setFillColor(c.dark); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(c.pop); ctx.setLineWidth(0.06 * s)
    for (x, h) in [(0.11, 0.16), (0.89, 0.16)] as [(CGFloat, CGFloat)] {
        ctx.beginPath(); ctx.move(to: p(x, 0.5 - h / 2)); ctx.addLine(to: p(x, 0.5 + h / 2)); ctx.strokePath()
    }
    ctx.setStrokeColor(c.light); ctx.setLineWidth(0.09 * s)
    ctx.beginPath()
    ctx.addLines(between: [p(0.24, 0.68), p(0.24, 0.32), p(0.5, 0.6), p(0.76, 0.32), p(0.76, 0.68)])
    ctx.strokePath()
}

/// 4. Nest: concentric arcs make a headband over two pop ear cups, cradling a light egg: a nest, or headphones.
func nest(_ ctx: CGContext, _ c: Colourway) {
    ctx.setFillColor(c.dark); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    let centre = p(0.5, 0.58)
    ctx.setLineCap(.round)
    for (r, colour) in [(0.33, c.light), (0.25, c.pop), (0.17, c.light)] as [(CGFloat, CGColor)] {
        ctx.setStrokeColor(colour); ctx.setLineWidth(0.055 * s)
        ctx.beginPath()
        ctx.addArc(center: centre, radius: r * s, startAngle: .pi * 1.0, endAngle: .pi * 2.0, clockwise: false)
        ctx.strokePath()
    }
    // Ear cups at the band's ends.
    ctx.setFillColor(c.pop)
    for x: CGFloat in [0.5 - 0.33, 0.5 + 0.33] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: (x - 0.07) * s, y: 0.54 * s, width: 0.14 * s, height: 0.24 * s),
                           cornerWidth: 0.05 * s, cornerHeight: 0.05 * s, transform: nil))
        ctx.fillPath()
    }
    // The egg in the nest.
    ctx.addPath(ellipsePath(0.5, 0.66, 0.085, 0.11, 0)); ctx.setFillColor(c.light); ctx.fillPath()
}

let designs: [(name: String, draw: (CGContext, Colourway) -> Void)] = [
    ("Record", record), ("Magpie", magpie), ("Wave", wave), ("Nest", nest),
]

// MARK: Output

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appending(path: "App/Resources/Assets.xcassets")

func writePNG(_ image: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

func scaled(_ image: CGImage, to px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func writeJSON(_ json: String, _ url: URL) { try! json.write(to: url, atomically: true, encoding: .utf8) }

func appIconSet(_ name: String, _ image: CGImage) {
    let dir = assets.appending(path: "\(name).appiconset")
    writePNG(image, dir.appending(path: "\(name).png"))
    writeJSON("""
    {
      "images" : [
        {
          "filename" : "\(name).png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """, dir.appending(path: "Contents.json"))
}

func previewSet(_ name: String, _ image: CGImage) {
    let dir = assets.appending(path: "IconPreview-\(name).imageset")
    writePNG(scaled(image, to: 180), dir.appending(path: "IconPreview-\(name).png"))
    writeJSON("""
    {
      "images" : [
        {
          "filename" : "IconPreview-\(name).png",
          "idiom" : "universal",
          "scale" : "3x"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """, dir.appending(path: "Contents.json"))
}

var rendered: [(name: String, image: CGImage)] = []
for design in designs {
    for colourway in colourways {
        let ctx = canvas(side, side)
        ctx.setShouldAntialias(true)
        design.draw(ctx, colourway)
        let image = ctx.makeImage()!
        let name = design.name + colourway.name
        appIconSet(name, image)
        previewSet(name, image)
        rendered.append((name, image))
        print("wrote \(name)")
    }
}

// The default icon's preview, from the asset catalog's own art.
let defaultURL = assets.appending(path: "AppIcon.appiconset/AppIcon.png")
let defaultSource = CGImageSourceCreateWithURL(defaultURL as CFURL, nil)!
let defaultImage = CGImageSourceCreateImageAtIndex(defaultSource, 0, nil)!
previewSet("Default", defaultImage)

// MARK: Preview sheet

let cell = 300, big = 200, small = 60, margin = 48, header = 120
let cols = colourways.count, rows = designs.count + 1
let sheetW = margin * 2 + cols * cell, sheetH = header + margin + rows * cell
let sheet = canvas(sheetW, sheetH)
sheet.setFillColor(rgb(0xFBFAF7)); sheet.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

func label(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, bold: Bool = false) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let attr = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0x16130F),
    ])
    let line = CTLineCreateWithAttributedString(attr)
    sheet.saveGState()
    sheet.textMatrix = .identity
    sheet.translateBy(x: x, y: y); sheet.scaleBy(x: 1, y: -1)   // text draws upright in the flipped context
    sheet.textPosition = .zero
    CTLineDraw(line, sheet)
    sheet.restoreGState()
}

func drawIcon(_ image: CGImage, x: CGFloat, y: CGFloat, size: CGFloat) {
    let rect = CGRect(x: x, y: y, width: size, height: size)
    sheet.saveGState()
    sheet.addPath(CGPath(roundedRect: rect, cornerWidth: size * 0.2237, cornerHeight: size * 0.2237, transform: nil))
    sheet.clip()
    // Undo the flip for the image, which CoreGraphics draws bottom-up.
    sheet.translateBy(x: 0, y: y * 2 + size); sheet.scaleBy(x: 1, y: -1)
    sheet.draw(image, in: rect)
    sheet.restoreGState()
}

label("Magpie app icons", CGFloat(margin), 64, size: 40, bold: true)
label("4 designs x 3 colourways, flat and matte, 3 colours each. Large and at 60 px.", CGFloat(margin), 100, size: 20)

let entries = [("Default", defaultImage)] + rendered.map { ($0.name, $0.image) }
for (i, entry) in entries.enumerated() {
    // Row 0: the default alone; then one row per design.
    let row = i == 0 ? 0 : 1 + (i - 1) / cols
    let col = i == 0 ? 0 : (i - 1) % cols
    let x = CGFloat(margin + col * cell), y = CGFloat(header + margin + row * cell)
    drawIcon(entry.1, x: x, y: y, size: CGFloat(big))
    drawIcon(scaled(entry.1, to: small * 2), x: x + CGFloat(big + 16), y: y + CGFloat(big - small), size: CGFloat(small))
    let title = entry.0 == "Default" ? "Default (green cover)"
        : entry.0.replacingOccurrences(of: "(?<=[a-z])(?=[A-Z])", with: " · ", options: .regularExpression)
    label(title, x, y + CGFloat(big + 34), size: 22)
}

let sheetURL = root.appending(path: "docs/storyboard/app-icons-preview.png")
writePNG(sheet.makeImage()!, sheetURL)
print("wrote \(sheetURL.path)")
