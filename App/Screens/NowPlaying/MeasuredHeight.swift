import CoreGraphics

/// When Now Playing stores a measured height (D43, QC). A store lays the page out again, which measures again; so a
/// height is kept in whole pixels and only replaced when it moved by half a point or more. Float noise between
/// passes (52.333 measured again as 52.333) then settles at once instead of feeding a layout loop.
enum MeasuredHeight {
    /// Smaller moves are the same height: float noise, or a pixel of rounding at 3x.
    static let tolerance: CGFloat = 0.5

    /// `height` rounded up to whole pixels at `scale`. Noise just past a pixel edge (a hundredth of a pixel) doesn't
    /// round up a whole pixel.
    static func pixelRounded(_ height: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0, height.isFinite else { return height }
        return (height * scale - 0.01).rounded(.up) / scale
    }

    /// The height to store for a new measure, or nil to keep `stored`.
    static func toStore(_ height: CGFloat, over stored: CGFloat?, scale: CGFloat) -> CGFloat? {
        let rounded = pixelRounded(height, scale: scale)
        guard let stored else { return rounded }
        return abs(rounded - stored) >= tolerance ? rounded : nil
    }
}
