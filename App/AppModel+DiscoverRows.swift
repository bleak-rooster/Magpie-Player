import AurralKit
import Foundation
import MagpieCore
import NavidromeKit

/// Round 26 L (owner, 2026-11-11): "the changes for picking up the aurral flow/playlist with the same name under
/// different users (two separate flows/playlists) still doesn't work" (D271–D275).
///
/// One row of Library › Discover: a Navidrome playlist that is Aurral's (it opens and plays), or an Aurral item
/// (a flow or a shared playlist, anyone's) that no Navidrome playlist is known to be, keyed by its Aurral id.
struct DiscoverRow: Identifiable, Equatable {
    enum Link: Equatable {
        case playlist(Playlist)
        case item(AurralFlow)
    }

    var link: Link

    /// Never a name: a playlist's Navidrome id, an item's Aurral id.
    var id: String {
        switch link {
        case .playlist(let playlist): "playlist:" + playlist.id
        case .item(let item): "item:" + item.id
        }
    }

    var name: String {
        switch link {
        case .playlist(let playlist): playlist.name
        case .item(let item): item.name
        }
    }
}

extension AppModel {
    /// Library › Discover's rows, in order.
    func discoverRows() async throws -> [DiscoverRow] {
        try await discoverPlaylists().map { DiscoverRow(link: .playlist($0)) }
    }

    /// The owner shown under a row's name (D205's rule).
    func discoverOwnerCaption(row: DiscoverRow) -> String? {
        switch row.link {
        case .playlist(let playlist): discoverOwnerCaption(playlistId: playlist.id)
        case .item: nil
        }
    }
}
