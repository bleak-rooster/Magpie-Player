import DesignSystem
import SwiftUI

/// The screen background: Immersive shows the cover blurred and darkened under glass (D2); the other
/// characters, and Immersive under Reduce Transparency, show the plain background.
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
