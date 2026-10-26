#if canImport(UIKit)
import UIKit

/// Record artwork for not-yet rows in CarPlay lists: the cover as the label of a vinyl disc, with
/// groove rings and a spindle hole, outside the circle transparent. Lists only; Now Playing always
/// shows the unmodified square cover (critique H4).
///
/// Thread-safe (`UIGraphicsImageRenderer`), so it runs off the main thread with the rest of the
/// artwork preparation.
public enum RoundArt {
    /// Fractions of the disc radius.
    static let labelRadius: CGFloat = 0.42
    static let holeRadius: CGFloat = 0.05
    static let grooveRings = 7

    /// Renders `image` as a record of `size` points at `scale` (pass the car screen's scale).
    public static func render(_ image: UIImage, size: CGSize, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = side / 2

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            func circle(_ fraction: CGFloat) -> CGRect {
                let rr = r * fraction
                return CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)
            }

            // Vinyl.
            cg.setFillColor(UIColor(red: 0.086, green: 0.075, blue: 0.059, alpha: 1).cgColor)
            cg.fillEllipse(in: circle(1))

            // Grooves between the label and the rim.
            cg.setStrokeColor(UIColor(white: 1, alpha: 0.10).cgColor)
            cg.setLineWidth(max(side / 160, 0.5))
            for i in 0..<grooveRings {
                let t = CGFloat(i + 1) / CGFloat(grooveRings + 1)
                cg.strokeEllipse(in: circle(labelRadius + 0.04 + t * (0.94 - labelRadius - 0.04)))
            }

            // Label: the cover, aspect-filled into a circle.
            cg.saveGState()
            cg.addEllipse(in: circle(labelRadius))
            cg.clip()
            let label = circle(labelRadius)
            let aspect = image.size.width > 0 && image.size.height > 0 ? image.size.width / image.size.height : 1
            var draw = label
            if aspect > 1 { draw.size.width = label.height * aspect } else { draw.size.height = label.width / aspect }
            draw.origin = CGPoint(x: label.midX - draw.width / 2, y: label.midY - draw.height / 2)
            image.draw(in: draw)
            cg.restoreGState()

            // Spindle hole.
            cg.setBlendMode(.clear)
            cg.fillEllipse(in: circle(holeRadius))
        }
    }
}
#endif
