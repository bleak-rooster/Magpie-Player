import AurralKit
import Foundation
import MagpieCore
import NavidromeKit

/// Round 26 L (D271): one Aurral item that is a row of its own, and whether it is the signed-in user's (by Aurral's
/// owner, never by a name).
struct DiscoverItemRow: Equatable {
    var item: AurralFlow
    var mine: Bool
}

/// What one read of Aurral knew when it identified Aurral's playlists (`identifyDiscoverPlaylists`).
struct DiscoverItemRead {
    var mine: [AurralFlow]
    var others: [AurralFlow]
    /// `[aurralItemId: playlistId]`, every claim this read.
    var claims: [String: String]
    /// Aurral's Navidrome playlists, each with its item as identified.
    var playlists: [DiscoverPlaylist]
    /// The playlists named as an item this read.
    var named: Set<String>
    var entries: [String: [Song]]
}

/// One row of Library › Discover: a Navidrome playlist that is Aurral's (it opens and plays), or an Aurral item (a flow
/// or a shared playlist, anyone's) no Navidrome playlist is known to be, keyed by its Aurral id.
struct DiscoverRow: Identifiable, Equatable {
    enum Link: Equatable {
        case playlist(Playlist)
        case item(AurralFlow, mine: Bool)
    }

    var link: Link

    /// Never a name: a playlist's Navidrome id, an item's Aurral id.
    var id: String {
        switch link {
        case .playlist(let playlist): "playlist:" + playlist.id
        case .item(let item, _): "item:" + item.id
        }
    }

    var name: String {
        switch link {
        case .playlist(let playlist): playlist.name
        case .item(let item, _): item.name
        }
    }
}

/// Round 26 L (owner, 2026-11-11): "Also the changes for picking up the aurral flow/playlist with the same name under
/// different users (two separate flows/playlists) still doesn't work." Their two "Chill" playlists (an Aurral admin's
/// and another user's) are "only in Aurral, they are not present in Navidrome"; build 27 showed "the playlist twice
/// without any usernames underneath" under everyone's and nothing under only mine (D271–D274).
///
/// Root cause (reproduced in `R26LSameNameNotInNavidromeTests`): Discover's rows were Navidrome playlists only
/// (`discoverPlaylists`), and which one is whose came only from evidence in a playlist (`DiscoverIdentity`). An item
/// with no Navidrome playlist had no row; two empty playlists of a shared name (what Aurral publishes before a
/// playlist's songs are in) carry no songs to prove anything, so neither was claimed (D202's Q1): both were "not
/// mine" and had no owner.
///
/// Now an Aurral item's identity is its Aurral id and its owner Aurral's own field (`AurralStatus.scoped`, D72 (5)):
/// - an item no Navidrome playlist is known to be is a row of its own, keyed by its Aurral id (`DiscoverRules.itemRows`);
///   the user's own always, another user's only with "Show everyone's flows" on, "sam" under it (D205's rule);
/// - Aurral's empty playlists no item claimed are never rows (phone, Home, the car): nothing to play, no owner known;
/// - a Navidrome claim is needed only to open and play songs: these rows don't open (nothing to play yet) and say why;
///   the car and Home list only what plays.
/// A user's own recipe flow without its playlist stays Your flows' row (round 16), never a second one here.
extension AppModel {
    nonisolated static let discoverHiddenPlaylistsKeyPrefix = "magpie.discoverHidden."
    nonisolated static func discoverHiddenPlaylistsKey(_ scope: String) -> String { discoverHiddenPlaylistsKeyPrefix + scope }

    /// D273: the playlists never listed: as last read, else as saved for the account (fix round 1, I1: before the
    /// launch's first read, or with Aurral down, the empty playlists stay hidden, as D189's others' do).
    var hiddenDiscoverPlaylistIds: Set<String> {
        guard aurralSetUp else { return [] }
        if discover.hiddenRead { return discover.hiddenPlaylistIds }
        guard let scope = navidromeScope else { return [] }
        return Set(appDefaults.stringArray(forKey: Self.discoverHiddenPlaylistsKey(scope)) ?? [])
    }

    /// Hook from `identifyDiscoverPlaylists`, on each read of Aurral: which items are rows of their own and which of
    /// Aurral's playlists are never rows. nil: no items listed (Z1's fail-closed status): no item rows, and the last
    /// hidden set is kept (such a read proves nothing new; fix round 1, I1).
    func noteDiscoverItemRows(_ read: DiscoverItemRead?) {
        guard let read else {
            discover.itemRows = []
            return
        }
        let claimed = Set(read.claims.values)
        // Linked: claimed this read, or kept with its playlist (D75's orphan, by its songs).
        let linked = Set(read.claims.keys).union(read.playlists.map(\.flow.id).filter { !$0.isEmpty })
        let unclaimed = read.playlists.map(\.playlist).filter { read.named.contains($0.id) && !claimed.contains($0.id) }
        // Empty: read and holding none; not read, as Navidrome counts it.
        let empty = Set(unclaimed.filter { read.entries[$0.id]?.isEmpty ?? ($0.songCount == 0) }.map(\.id))
        let rows = DiscoverRules.itemRows(items: read.mine + read.others, linked: linked, unclaimed: unclaimed, empty: empty)
        let mine = Set(read.mine.map(\.id))
        let byId = Dictionary((read.mine + read.others).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        discover.itemRows = rows.items.compactMap { id in byId[id].map { DiscoverItemRow(item: $0, mine: mine.contains(id)) } }
        discover.hiddenPlaylistIds = rows.hidden
        discover.hiddenRead = true
        if let scope = navidromeScope {   // saved per account beside D189's others' (fix round 1, I1)
            appDefaults.set(rows.hidden.sorted(), forKey: Self.discoverHiddenPlaylistsKey(scope))
        }
    }

    /// Library › Discover's rows: Aurral's playlists (as `discoverPlaylists`), then the items that are rows of their own
    /// (the user's; another user's only with "Show everyone's flows" on), as Aurral lists them. Not a recipe flow Your
    /// flows already shows, nor one being deleted.
    func discoverRows() async throws -> [DiscoverRow] {
        let playlists = try await discoverPlaylists().map { DiscoverRow(link: .playlist($0)) }
        guard aurralSetUp, !isOffline, !discover.flowsNotPermitted else { return playlists }
        let inYourFlows = aurralCanManageFlows ? Set(unpublishedRecipeFlows.map(\.id)) : []
        let items = discover.itemRows.filter { row in
            (row.mine || showEveryonesFlows) && !inYourFlows.contains(row.item.id)
                && !discover.deletingFlowIds.contains(row.item.id) && discover.removing[row.item.id] == nil
        }
        return playlists + items.map { DiscoverRow(link: .item($0.item, mine: $0.mine)) }
    }

    /// The owner shown under a row's name (D205's rule, `OwnerCaption.text`): only while everyone's are shown, only for
    /// another user's, as Aurral names its owner (an item) or as its claiming item does (a playlist).
    func discoverOwnerCaption(row: DiscoverRow) -> String? {
        switch row.link {
        case .playlist(let playlist): return discoverOwnerCaption(playlistId: playlist.id)
        case .item(let item, let mine):
            guard showEveryonesFlows, !mine else { return nil }
            return OwnerCaption.text(owner: item.ownerUsername, signedInUser: discover.connection?.username)
        }
    }

    /// Why an item's row doesn't open (no dead buttons): the user's own with songs on the way, "Downloading 3/12";
    /// otherwise "Not ready yet. Check back later." (none of its songs is in a playlist yet).
    func discoverItemState(_ item: AurralFlow, mine: Bool) -> (text: String, symbol: String) {
        if mine, let stats = discover.status?.flowStats[item.id], let total = stats.total, total > 0 {
            let waiting = (stats.pending ?? 0) + (stats.downloading ?? 0)
            if waiting > 0 {
                return (DiscoverPagesCopy.downloading(min(total, max(0, stats.done ?? 0)), total), "arrow.down.circle.dotted")
            }
        }
        return (DiscoverPagesCopy.notReady, "clock")
    }
}
