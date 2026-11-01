import DesignSystem
import SwiftUI

/// The screen background: Immersive shows the cover blurred and darkened under glass (D2), tinted by the cover's
/// colours when `immersiveArt` has given the theme its palette (R13); the other characters, and Immersive under
/// Reduce Transparency, show the plain background.
struct ArtBackdrop: View {
    let coverArtId: String?
    @Environment(\.magpieTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if theme.character == .immersive, !reduceTransparency {
            Artwork(coverArtId, side: 300) { ImmersiveBackdrop(image: $0) }
        } else {
            ImmersiveBackdrop(image: nil)
        }
    }
}

extension View {
    /// R13: in Immersive, everything inside takes its colours from this cover: the background, the accent and the
    /// tint of controls. The palette is worked out once per cover (`ArtPaletteCache`); until it is, and in the other
    /// characters or under Increase Contrast, the theme is unchanged. Put `.background { ArtBackdrop(...) }` inside it.
    func immersiveArt(coverArtId: String?) -> some View { modifier(ImmersiveArtTheme(coverArtId: coverArtId)) }
}

private struct ImmersiveArtTheme: ViewModifier {
    let coverArtId: String?
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    /// The last palette worked out, with its cover.
    @State private var loaded: (id: String, palette: ArtPalette)?

    func body(content: Content) -> some View {
        let wanted = theme.character == .immersive ? coverArtId : nil
        let palette = wanted.flatMap { id in loaded?.id == id ? loaded?.palette : ArtPaletteCache.shared.cached(id) }
        let resolved = ImmersiveArt.theme(theme, art: palette, increaseContrast: contrast == .increased)
        content
            .magpieTheme(resolved)
            .tint(resolved.colors(for: scheme).accentInkColor)
            .task(id: wanted) {
                guard let wanted, ArtPaletteCache.shared.cached(wanted) == nil else { return }
                if let palette = await model.artPalette(wanted) { loaded = (wanted, palette) }
            }
    }
}
