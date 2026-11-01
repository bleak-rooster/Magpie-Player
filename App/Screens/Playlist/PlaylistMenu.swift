import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// The playlist page's ⋯ menu (round 11 R8, as the UX appraisal places it: Download is the capsule under Play and
/// Shuffle, as on Album). A playlist the user doesn't own (or any, offline) shows only the items that don't change it.
enum PlaylistMenuItem: Hashable, CaseIterable {
    case addToQueue, addToPlaylist, rename, reloadArtwork, delete

    static func items(editable: Bool) -> [PlaylistMenuItem] {
        allCases.filter { editable || !$0.edits }
    }

    /// Changes the playlist on the server.
    var edits: Bool { self == .rename || self == .delete }
}

/// The `ellipsis.circle` menu in the playlist page's toolbar.
struct PlaylistMoreMenu: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    let songs: [Song]
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        Menu {
            ForEach(PlaylistMenuItem.items(editable: model.canEdit(playlist)), id: \.self) { item in
                button(item)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("playlist-more")
    }

    @ViewBuilder private func button(_ item: PlaylistMenuItem) -> some View {
        switch item {
        case .addToQueue:
            Button("Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                model.player.addToEnd(songs)
            }
            .disabled(songs.isEmpty)
        case .addToPlaylist:
            if !model.isOffline {
                Button(PlaylistCopy.addToPlaylist, systemImage: "text.badge.plus") {
                    model.askToAddToPlaylist(songs.map(\.id))
                }
                .disabled(songs.isEmpty)
            }
        case .rename:
            Button("Rename\u{2026}", systemImage: "pencil", action: rename)
        case .reloadArtwork:
            if let coverArtId = playlist.coverArtId, !model.isOffline {
                Button("Reload artwork", systemImage: "arrow.clockwise") { Task { await model.reloadArtwork(coverArtId) } }
            }
        case .delete:
            Button("Delete playlist\u{2026}", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}
