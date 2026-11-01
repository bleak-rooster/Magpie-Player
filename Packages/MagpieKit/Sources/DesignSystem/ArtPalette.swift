import Foundation

/// R13: Immersive's colours, drawn from the cover on the phone. `dominant` is the cover's most common colour, `accent`
/// its most vivid one (set apart from the dominant hue when the cover has one). Everything derived from them is
/// checked here, once, so the theme only reads finished tokens:
/// - `background` and `glow` are the two colours darkened to under the Immersive floor (#2A2A2A), so every text pair
///   validated against the floor holds on them, and on any mix of them with the scrimmed art (D15, a11y C1);
/// - `accentTokens` is the accent lightened until it reads at WCAG AA (4.5:1) on the floor, or nil when the cover is
///   grey or no lightening gets there: the theme's own accent stays (the fallback).
public struct ArtPalette: Sendable, Hashable {
    public let dominant: PaletteColor
    public let accent: PaletteColor
    /// The page background: the dominant colour, darkened.
    public let background: PaletteColor
    /// The gradient's other end: the accent, darkened.
    public let glow: PaletteColor
    public let accentTokens: AccentTokens?

    public struct AccentTokens: Sendable, Hashable {
        /// Capsules, arcs, badges.
        public let fill: PaletteColor
        /// Accent text and small glyphs.
        public let ink: PaletteColor
        /// Text on `fill`.
        public let on: PaletteColor
    }

    public init(dominant: PaletteColor, accent: PaletteColor) {
        self.dominant = dominant
        self.accent = accent
        background = Self.darkened(dominant, to: Self.backgroundLuminance)
        glow = Self.darkened(accent, to: Self.backgroundLuminance)
        accentTokens = Self.accentTokens(for: accent)
    }

    // MARK: Contrast

    /// Backgrounds sit a little under the floor's luminance.
    public static var backgroundLuminance: Double { ImmersiveScrim.maxLuminance * 0.85 }
    /// Covers greyer than this keep the theme accent: a lightened grey is no accent.
    public static let minimumAccentSaturation: Double = 0.18
    /// How far the accent may be mixed towards white before it stops being the cover's colour.
    public static let maximumLightening: Double = 0.8

    /// The surface buttons sit on (14% white over the floor): the accent glyph (the star) needs 3:1 on it.
    static var solidSurfaceOverFloor: PaletteColor { PaletteColor(hex: 0xFFFFFF, alpha: 0.14).composited(over: ImmersiveScrim.floor) }

    /// True when `ink` reads on everything Immersive puts under text: 4.5:1 on the floor, 3:1 on a solid surface.
    public static func passesAA(_ ink: PaletteColor) -> Bool {
        Contrast.ratio(ink, on: ImmersiveScrim.floor) >= 4.5 && Contrast.ratio(ink, on: solidSurfaceOverFloor) >= 3
    }

    static func accentTokens(for accent: PaletteColor) -> AccentTokens? {
        guard accent.hsv.s >= minimumAccentSaturation else { return nil }
        var t = 0.0
        while t <= maximumLightening + 1e-9 {
            let ink = accent.mixed(with: PaletteColor(hex: 0xFFFFFF), by: t)
            if passesAA(ink) {
                // Text on the fill: the accent's own darkest shade, or black when that isn't dark enough.
                let deep = darkened(accent, to: 0.01)
                let on = Contrast.ratio(deep, on: ink) >= 4.5 ? deep : PaletteColor(hex: 0x000000)
                guard Contrast.ratio(on, on: ink) >= 4.5 else { return nil }
                return AccentTokens(fill: ink, ink: ink, on: on)
            }
            t += 0.05
        }
        return nil
    }

    /// `color` scaled towards black (hue kept) until its luminance is at most `target`; unchanged if already there.
    static func darkened(_ color: PaletteColor, to target: Double) -> PaletteColor {
        let opaque = color.composited(over: PaletteColor(hex: 0x000000))
        guard opaque.relativeLuminance > target else { return opaque }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if opaque.scaled(by: mid).relativeLuminance > target { hi = mid } else { lo = mid }
        }
        return opaque.scaled(by: lo)
    }

    // MARK: Extraction

    /// The palette of an RGBA8 bitmap (premultiplied or not; pixels under half opacity are skipped). Deterministic:
    /// colours are counted in 4-bit buckets, so pixel order never matters, and ties go to the lower bucket.
    /// Nil when no pixel is opaque enough.
    public static func extract(rgba: [UInt8], width: Int, height: Int) -> ArtPalette? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in 0..<(width * height) {
            let o = i * 4
            let (r, g, b, a) = (Int(rgba[o]), Int(rgba[o + 1]), Int(rgba[o + 2]), Int(rgba[o + 3]))
            guard a >= 128 else { continue }
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let old = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
        }
        guard !buckets.isEmpty else { return nil }
        let colours = buckets.keys.sorted().map { key -> (key: Int, count: Int, color: PaletteColor) in
            let v = buckets[key]!
            let n = Double(v.count) * 255
            return (key, v.count, PaletteColor(red: Double(v.r) / n, green: Double(v.g) / n, blue: Double(v.b) / n))
        }
        // `sorted()` keys + strict `>` keep the lowest key on a tie.
        var dominant = colours[0]
        for c in colours.dropFirst() where c.count > dominant.count { dominant = c }

        let dominantHSV = dominant.color.hsv
        func vividness(_ c: (key: Int, count: Int, color: PaletteColor)) -> Double {
            let hsv = c.color.hsv
            guard hsv.s >= minimumAccentSaturation, hsv.v >= 0.2 else { return 0 }
            return Double(c.count) * hsv.s * hsv.s * hsv.v
        }
        func best(_ candidates: [(key: Int, count: Int, color: PaletteColor)]) -> (key: Int, count: Int, color: PaletteColor)? {
            var top: (key: Int, count: Int, color: PaletteColor)?
            var topScore = 0.0
            for c in candidates {
                let score = vividness(c)
                if score > topScore { top = c; topScore = score }
            }
            return top
        }
        // Prefer a hue of its own when the dominant colour has one; otherwise the most vivid colour at all.
        let distinct = dominantHSV.s >= minimumAccentSaturation
            ? colours.filter { $0.key != dominant.key && hueDistance($0.color.hsv.h, dominantHSV.h) >= 30 }
            : colours
        let accent = best(distinct) ?? best(colours) ?? dominant
        return ArtPalette(dominant: dominant.color, accent: accent.color)
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

/// R13: the theme a page shows. Only Immersive takes the cover's colours, and never under Increase Contrast, where the
/// fixed Immersive palette (validated at the floor) stays (D15).
public enum ImmersiveArt {
    public static func theme(_ base: Theme, art: ArtPalette?, increaseContrast: Bool) -> Theme {
        var theme = base
        theme.art = base.character == .immersive && !increaseContrast ? art : nil
        return theme
    }
}

extension PaletteColor {
    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.init(hex: 0)
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// Mixed in sRGB towards `other`; `t` = 0 is self, 1 is `other`.
    func mixed(with other: PaletteColor, by t: Double) -> PaletteColor {
        PaletteColor(red: red + (other.red - red) * t, green: green + (other.green - green) * t,
                     blue: blue + (other.blue - blue) * t, alpha: alpha)
    }

    func scaled(by k: Double) -> PaletteColor {
        PaletteColor(red: red * k, green: green * k, blue: blue * k, alpha: alpha)
    }

    /// Hue in degrees, saturation and value in 0...1.
    var hsv: (h: Double, s: Double, v: Double) {
        let mx = max(red, green, blue), mn = min(red, green, blue), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == red { h = 60 * ((green - blue) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == green { h = 60 * ((blue - red) / d + 2) }
            else { h = 60 * ((red - green) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}
