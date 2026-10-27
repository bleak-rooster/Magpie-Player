import SwiftUI

/// An sRGB colour with alpha. Kept as plain numbers (not `Color`) so contrast can be computed in tests.
public struct PaletteColor: Sendable, Hashable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// This colour flattened over an opaque `backdrop`.
    public func composited(over backdrop: PaletteColor) -> PaletteColor {
        var out = backdrop
        out.red = red * alpha + backdrop.red * (1 - alpha)
        out.green = green * alpha + backdrop.green * (1 - alpha)
        out.blue = blue * alpha + backdrop.blue * (1 - alpha)
        out.alpha = 1
        return out
    }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }
}

public enum Contrast {
    /// WCAG contrast ratio of `foreground` (flattened over `background` if translucent) against `background`.
    public static func ratio(_ foreground: PaletteColor, on background: PaletteColor) -> Double {
        let a = foreground.composited(over: background).relativeLuminance
        let b = background.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Non-colour design tokens: spacing (4 pt rhythm), shape, motion.
public enum Tokens {
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        /// Side margin; 20 on Large-title pages.
        public static let margin: CGFloat = 16
        public static let largeTitleMargin: CGFloat = 20
    }
    public enum Radius {
        /// Art corner radius at <= 64 pt.
        public static let art: CGFloat = 8
        /// Art corner radius at hero sizes.
        public static let hero: CGFloat = 12
        public static let card: CGFloat = 20
        public static func art(forSide side: CGFloat) -> CGFloat { side <= 64 ? art : hero }
    }
    public enum Motion {
        /// 33 1/3 rpm.
        public static let recordTurn: Double = 1.8
        /// Sleeve morph (circle to rounded square) on Keep.
        public static let keepMorph: Animation = .spring(duration: 0.45, bounce: 0.3)
        /// What replaces motion under Reduce Motion.
        public static let reduced: Animation = .easeInOut(duration: 0.2)
    }
    /// Minimum interactive size (HIG).
    public static let minHitSize: CGFloat = 44
    /// Sheen gradient: special moments only (Keep, the Lossless shimmer).
    public static let sheenGradient = LinearGradient(
        colors: [Color(.sRGB, red: 0x2E / 255, green: 0x6B / 255, blue: 0xD8 / 255),
                 Color(.sRGB, red: 0x24 / 255, green: 0xB3 / 255, blue: 0xA8 / 255),
                 Color(.sRGB, red: 0x7B / 255, green: 0x4F / 255, blue: 0xD6 / 255)],
        startPoint: UnitPoint(x: 0.0, y: 0.25), endPoint: UnitPoint(x: 1.0, y: 0.75))
}
