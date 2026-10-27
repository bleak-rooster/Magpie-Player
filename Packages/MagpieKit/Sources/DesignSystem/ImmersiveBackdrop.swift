import SwiftUI

/// Immersive-lite (D2): the album art, blurred and darkened, behind Now Playing and Album.
/// No particles, no visualizer. Everything that sits on it is validated against the scrim floor (D15).
public enum ImmersiveScrim {
    /// Darkest-allowed ceiling for anything under text: #2A2A2A.
    public static let floor = PaletteColor(hex: 0x2A2A2A)
    public static var maxLuminance: Double { floor.relativeLuminance }

    /// Black scrim laid over the blurred art. Sized for the worst case, pure white art:
    /// white at 1 - 0.85 = 0.15 (sRGB) is below the #2A2A2A floor (0.165).
    public static let opacity: Double = 0.85

    /// What the backdrop looks like under text for art of a given colour (flattened, opaque).
    public static func luminance(underScrimOf art: PaletteColor) -> Double {
        PaletteColor(hex: 0x000000, alpha: opacity).composited(over: art).relativeLuminance
    }

    /// True when text over art this bright still sits on a backdrop no lighter than the floor.
    public static func holdsFloor(forArt art: PaletteColor) -> Bool {
        luminance(underScrimOf: art) <= maxLuminance
    }

    /// Blur radius for the art; large enough that no detail competes with text.
    public static let blurRadius: CGFloat = 48
}

/// How the Immersive backdrop is drawn.
public enum ImmersiveBackdropMode: Sendable, Equatable {
    /// Blurred, darkened art.
    case art
    /// Solid surface (Reduce Transparency).
    case solid

    /// Reduce Transparency means opaque surfaces: no art, no blur. (Low Power needs nothing: Immersive-lite
    /// has no motion to drop, so the still art backdrop is already what it shows.)
    public static func resolve(isImmersive: Bool, reduceTransparency: Bool, hasArt: Bool) -> Self? {
        guard isImmersive else { return nil }
        return reduceTransparency || !hasArt ? .solid : .art
    }
}

public extension Palette {
    /// `surface` flattened over `bg`: a solid fill for capsules and buttons that sit over the backdrop (a11y C1).
    var solidSurfaceColor: Color { surface.composited(over: bg).color }
}

/// The backdrop itself. Non-interactive. In Signature and Classic it is just the plain background.
public struct ImmersiveBackdrop: View {
    private let image: Image?
    @Environment(\.magpieTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(image: Image?) { self.image = image }

    public var body: some View {
        let p = theme.colors(for: scheme)
        let mode = ImmersiveBackdropMode.resolve(isImmersive: theme.character == .immersive,
                                                 reduceTransparency: reduceTransparency, hasArt: image != nil)
        ZStack {
            p.bgColor
            if mode == .art, let image {
                GeometryReader { geo in
                    image.resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: ImmersiveScrim.blurRadius, opaque: true)
                        .clipped()
                }
                .overlay(Color.black.opacity(ImmersiveScrim.opacity))
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: mode)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
