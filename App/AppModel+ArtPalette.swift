import DesignSystem
import Foundation

/// R13: Immersive's colours for a cover, from the small cover image (memory, then disk, then the server, as for any
/// artwork), cached per cover id.
extension AppModel {
    func artPalette(_ coverArtId: String) async -> ArtPalette? {
        await ArtPaletteCache.shared.palette(for: coverArtId) { [weak self] in
            await self?.artworkImage(coverArtId, size: 120)
        }
    }
}
