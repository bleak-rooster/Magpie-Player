import SwiftUI

/// The Character dial (Settings > Appearance). Layout is identical across all three; only the skin changes.
public enum Character: String, CaseIterable, Codable, Sendable { case classic, signature, immersive }

/// User accent. Sheen is the default.
public enum AccentChoice: String, CaseIterable, Codable, Sendable { case sheen, tangerine, ultramarine }

public struct Palette: Sendable, Hashable {
    public var bg, surface, ink, ink2, sep: PaletteColor
    /// Fill colour (capsules, arcs, badges).
    public var accent: PaletteColor
    /// Text-safe accent: use for accent-coloured text and small glyphs on `bg`/`surface`.
    public var accentInk: PaletteColor
    /// Text on an `accent` fill.
    public var onAccent: PaletteColor

    public var bgColor: Color { bg.color }
    public var surfaceColor: Color { surface.color }
    public var inkColor: Color { ink.color }
    public var ink2Color: Color { ink2.color }
    public var sepColor: Color { sep.color }
    public var accentColor: Color { accent.color }
    public var accentInkColor: Color { accentInk.color }
    public var onAccentColor: Color { onAccent.color }
}

public struct Theme: Sendable, Hashable {
    public var character: Character
    public var accent: AccentChoice

    public init(character: Character = .signature, accent: AccentChoice = .sheen) {
        self.character = character
        self.accent = accent
    }

    /// Signature and Immersive set display titles in New York (system serif).
    public var usesSerifDisplay: Bool { character != .classic }

    public func colors(for scheme: ColorScheme) -> Palette {
        let dark = character == .immersive || scheme == .dark
        let a = Theme.accentTokens(accent, dark: dark)
        switch character {
        case .classic:
            return dark
                ? Palette(bg: .init(hex: 0x000000), surface: .init(hex: 0x1C1C1E), ink: .init(hex: 0xFFFFFF),
                          ink2: .init(hex: 0x98989F), sep: .init(hex: 0x38383A),
                          accent: a.fill, accentInk: a.ink, onAccent: a.on)
                : Palette(bg: .init(hex: 0xFFFFFF), surface: .init(hex: 0xF2F2F7), ink: .init(hex: 0x000000),
                          ink2: .init(hex: 0x6C6C70), sep: .init(hex: 0xD1D1D6),
                          accent: a.fill, accentInk: a.ink, onAccent: a.on)
        case .signature:
            return dark
                ? Palette(bg: .init(hex: 0x0E0D0C), surface: .init(hex: 0x1A1816), ink: .init(hex: 0xF4F1EA),
                          ink2: .init(hex: 0xA39C90), sep: .init(hex: 0x2C2925),
                          accent: a.fill, accentInk: a.ink, onAccent: a.on)
                : Palette(bg: .init(hex: 0xFBFAF7), surface: .init(hex: 0xF2EFE9), ink: .init(hex: 0x16130F),
                          ink2: .init(hex: 0x6B655C), sep: .init(hex: 0xE3DED5),
                          accent: a.fill, accentInk: a.ink, onAccent: a.on)
        case .immersive:
            // Real backgrounds are art-derived and darkened to a luminance floor (a11y C1);
            // #2A2A2A is that floor, so it is the worst case these tokens are validated against.
            return Palette(bg: .init(hex: 0x2A2A2A), surface: .init(hex: 0xFFFFFF, alpha: 0.14),
                           ink: .init(hex: 0xFFFFFF), ink2: .init(hex: 0xFFFFFF, alpha: 0.72),
                           sep: .init(hex: 0xFFFFFF, alpha: 0.16),
                           accent: a.fill, accentInk: a.ink, onAccent: a.on)
        }
    }

    private static func accentTokens(_ choice: AccentChoice, dark: Bool)
        -> (fill: PaletteColor, ink: PaletteColor, on: PaletteColor) {
        switch choice {
        case .sheen:
            // Light-mode text/small elements use accent-ink #0E6F68; fills stay #3CC4B8 with #04201D text (D15).
            return (.init(hex: 0x3CC4B8), .init(hex: dark ? 0x3CC4B8 : 0x0E6F68), .init(hex: 0x04201D))
        case .tangerine:
            return (.init(hex: 0xF25C05), .init(hex: dark ? 0xFF8A4C : 0xC2410C), .init(hex: 0x1F0A00))
        case .ultramarine:
            return (.init(hex: 0x3D5AFE), .init(hex: dark ? 0x8C9EFF : 0x3D5AFE), .init(hex: 0xFFFFFF))
        }
    }

    // MARK: Type

    /// Display titles (Large title, Title 1/2, album titles): New York semibold in Signature/Immersive, SF in Classic.
    /// Pair with `.magpieDisplayTracking(_:)` for the -0.4 pt tracking.
    public func displayFont(_ style: Font.TextStyle) -> Font {
        usesSerifDisplay ? .system(style, design: .serif, weight: .semibold) : .system(style, design: .default, weight: .semibold)
    }

    /// Times, counts, days left: SF Pro Rounded with tabular digits.
    public func numberFont(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .rounded).monospacedDigit()
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme() }

public extension EnvironmentValues {
    var magpieTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

public extension View {
    func magpieTheme(_ theme: Theme) -> some View { environment(\.magpieTheme, theme) }
}

/// Resolves the palette for the current theme and colour scheme.
struct ThemedPalette: DynamicProperty {
    @Environment(\.magpieTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    var palette: Palette { theme.colors(for: scheme) }
}

public extension View {
    /// Display-title font plus the Signature/Immersive -0.4 pt tracking.
    func magpieDisplay(_ style: Font.TextStyle) -> some View { modifier(DisplayTitle(style: style)) }
}

private struct DisplayTitle: ViewModifier {
    @Environment(\.magpieTheme) private var theme
    let style: Font.TextStyle
    func body(content: Content) -> some View {
        content.font(theme.displayFont(style)).tracking(theme.usesSerifDisplay ? -0.4 : 0)
    }
}
