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
    /// R13: the cover's colours, for Immersive only (nil elsewhere, and under Increase Contrast; see `ImmersiveArt`).
    public var art: ArtPalette?

    public init(character: Character = .signature, accent: AccentChoice = .sheen, art: ArtPalette? = nil) {
        self.character = character
        self.accent = accent
        self.art = art
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
            // R13: with the cover's palette, its darkened colour is the background and its accent (AA-checked
            // against the floor) the accent; a cover without one keeps the user's accent.
            let tokens = art?.accentTokens
            return Palette(bg: art?.background ?? .init(hex: 0x2A2A2A), surface: .init(hex: 0xFFFFFF, alpha: 0.14),
                           ink: .init(hex: 0xFFFFFF), ink2: .init(hex: 0xFFFFFF, alpha: 0.72),
                           sep: .init(hex: 0xFFFFFF, alpha: 0.16),
                           accent: tokens?.fill ?? a.fill, accentInk: tokens?.ink ?? a.ink, onAccent: tokens?.on ?? a.on)
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

    /// Display titles (Large title, Title 1/2, album titles): New York semibold in Signature, SF in Classic.
    /// Immersive (R13) has its own pairing, one size step up for bolder contrast with the SF Pro text:
    /// New York black/heavy/bold for Large title, Title 1 and Title 2 (page, album and Now Playing titles, shelf
    /// headings), and SF Pro Compressed heavy for Title 3 section headings. All follow Dynamic Type (D15).
    /// `.magpieDisplay(_:)` applies the font with `displayTracking(_:)`.
    public func displayFont(_ style: Font.TextStyle) -> Font {
        switch character {
        case .classic: .system(style, design: .default, weight: .semibold)
        case .signature: .system(style, design: .serif, weight: .semibold)
        case .immersive:
            switch style {
            case .largeTitle: .system(.largeTitle, design: .serif, weight: .black)
            case .title: .system(.largeTitle, design: .serif, weight: .heavy)
            case .title2: .system(.title, design: .serif, weight: .bold)
            case .title3: .system(.title2, weight: .heavy).width(.compressed)
            case .headline: .system(.title3, weight: .heavy).width(.compressed)
            default: .system(style, design: .serif, weight: .bold)
            }
        }
    }

    /// Tracking for `displayFont(_:)`: -0.4 pt in Signature; Immersive pulls its big serif tighter and opens up its
    /// compressed headings.
    public func displayTracking(_ style: Font.TextStyle) -> CGFloat {
        switch character {
        case .classic: 0
        case .signature: -0.4
        case .immersive:
            switch style {
            case .largeTitle: -0.8
            case .title: -0.6
            case .title3, .headline: 0.3
            default: -0.5
            }
        }
    }

    /// Times, counts, days left: SF Pro Rounded with tabular digits; Immersive reads them out in SF Mono.
    public func numberFont(_ style: Font.TextStyle = .footnote) -> Font {
        character == .immersive ? .system(style, design: .monospaced, weight: .medium)
                                : .system(style, design: .rounded).monospacedDigit()
    }

    /// Capsule labels (Play, Shuffle, Try, Keep): SF Pro footnote; Immersive's are SF Pro Compressed, bolder and larger.
    public var capsuleFont: Font {
        character == .immersive ? .system(.callout, weight: .bold).width(.compressed) : .footnote.weight(.semibold)
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
    /// Display-title font plus its tracking (`Theme.displayTracking`).
    func magpieDisplay(_ style: Font.TextStyle) -> some View { modifier(DisplayTitle(style: style)) }
}

private struct DisplayTitle: ViewModifier {
    @Environment(\.magpieTheme) private var theme
    let style: Font.TextStyle
    func body(content: Content) -> some View {
        content.font(theme.displayFont(style)).tracking(theme.displayTracking(style))
    }
}
