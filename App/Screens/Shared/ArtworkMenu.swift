import SwiftUI

extension View {
    /// "Reload artwork" (P4) in the context menu of an album, artist or playlist's row, tile or page header: its cached
    /// sizes go and it is fetched again. Not offered offline (nothing could be fetched) or without a cover.
    func reloadArtworkMenu(_ coverArtId: String?) -> some View { modifier(ReloadArtworkMenu(coverArtId: coverArtId)) }
}

private struct ReloadArtworkMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    let coverArtId: String?

    func body(content: Content) -> some View {
        if let coverArtId, !model.isOffline {
            content.contextMenu {
                Button("Reload artwork", systemImage: "arrow.clockwise") {
                    Task { await model.reloadArtwork(coverArtId) }
                }
            }
        } else {
            content
        }
    }
}
