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
/// Round 28 O3 (D341): on the phone's page (offline, or the phone's copy of a failed read) only Add to queue: the rest
/// needs the server.
struct PlaylistMoreMenu: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    let songs: [Song]
    /// Round 28 O3: the server's page, online.
    var onServer = true
    let rename: () -> Void
    let delete: () -> Void

    /// Round 28 O3 (D341, D345): the items a page shows: offline or on the phone's page, Add to queue alone.
    static func items(editable: Bool, onServer: Bool, offline: Bool) -> [PlaylistMenuItem] {
        guard onServer, !offline else { return [.addToQueue] }
        return PlaylistMenuItem.items(editable: editable)
    }

    var body: some View {
        Menu {
            ForEach(Self.items(editable: model.canEdit(playlist), onServer: onServer, offline: model.isOffline),
                    id: \.self) { item in
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
