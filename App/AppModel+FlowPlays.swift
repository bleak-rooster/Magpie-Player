import CarPlayUI
import Foundation
import MagpieCore

/// Round 27 H (owner, 2026-11-14): flows by last played on Home and in the car, whose flow it is, and the car's
/// "aurral playlists/flows and playlists combined" (D297–D300).
///
/// - A Discover playlist's play is recorded when it starts playing: its page and Home's quick grid through
///   `noteRecentlyPlayed`, the car through `CarPlayLibrary.notePlaylistPlayed(id:)`. Per account, at most 300, in the
///   Home folder (`FlowPlaysStore`); removed at sign-out.
/// - Home's Your flows follow Settings › Home & Library › Order (Last played by default, or A to Z, D298); the car's
///   Discover home shelf is always by last played (D297). Library › Discover keeps the server's order (D187).
extension AppModel {
    /// When each Discover playlist last started playing, for the signed-in account; none signed out.
    var flowPlays: [String: Date] {
        guard let scope = navidromeScope else { return [:] }
        if let slot = flowPlaysSlot, slot.scope == scope { return slot.plays }
        let plays = FlowPlaysStore(root: dataDirectory, scope: scope).load()
        flowPlaysSlot = (scope, plays)
        return plays
    }

    /// Records that `playlistId` started playing, when it is a Discover playlist (never another playlist). Saved at
    /// once. Fix round 1 (M3, design L2): with Last played, the Your flows shelf already loaded is put in the new
    /// order the next time Home shows (`reorderWhenShown`): nothing is read again, and nothing moves under the owner's
    /// eyes. Fix round 2 (R1): a flow the loaded shelf doesn't hold (past its first `homeShelfSize`, or a shelf not
    /// read yet) can't be brought in by a new order, so the shelf is read again then instead (`readAgainWhenShown`).
    func noteFlowPlayed(playlistId: String, at date: Date = Date()) {
        guard let scope = navidromeScope, isDiscoverPlaylist(id: playlistId) else { return }
        let plays = FlowPlays.noting(playlistId, at: date, in: flowPlays)
        flowPlaysSlot = (scope, plays)
        FlowPlaysStore(root: dataDirectory, scope: scope).save(plays)
        guard preferences.layout.homeFlowsOrder == .lastPlayed, let feed = homeFeedSlot else { return }
        guard Self.holds(feed.load?.found[.discover]?.items ?? [], playlistId: playlistId) else {
            return feed.readAgainWhenShown(.discover)
        }
        feed.reorderWhenShown(.discover) { [weak self] items in
            guard let self else { return items }
            return Self.reordered(items, preferences.layout.homeFlowsOrder, lastPlayed: flowPlays)
        }
    }

    /// Whether Your flows' loaded tiles include the flow `playlistId`.
    nonisolated static func holds(_ items: [HomeShelf.Item], playlistId: String) -> Bool {
        items.contains { if case .playlist(let p) = $0 { p.id == playlistId } else { false } }
    }

    /// Your flows' tiles in `order`: its flows sorted, the For you tiles after them as they were.
    nonisolated static func reordered(_ items: [HomeShelf.Item], _ order: HomeFlowsOrder,
                                      lastPlayed: [String: Date]) -> [HomeShelf.Item] {
        let flows = items.compactMap { item -> Playlist? in if case .playlist(let p) = item { p } else { nil } }
        let rest = items.filter { if case .playlist = $0 { false } else { true } }
        return order.sorted(flows, lastPlayed: lastPlayed).map(HomeShelf.Item.playlist) + rest
    }

    /// Sign-out: the plays in memory go (their file goes with Home's folder, `forgetHomeShelves`).
    func forgetFlowPlays() {
        flowPlaysSlot = nil
    }

    /// Settings › Home & Library › Order (D298): saved, and Home's Your flows reads again in the new order.
    func setHomeFlowsOrder(_ order: HomeFlowsOrder) {
        updatePreferences { $0.layout.homeFlowsOrder = order }
        homeFeedSlot?.sectionsChanged([.discover])
    }

    /// Home's Your flows, in the owner's order (D298).
    func homeFlowsSorted(_ flows: [Playlist]) -> [Playlist] {
        preferences.layout.homeFlowsOrder.sorted(flows, lastPlayed: flowPlays)
    }

    /// The car's Discover home shelf (D297): Discover's playlists, played newest first, then A to Z, always.
    func carDiscoverFlows() async throws -> [Playlist] {
        HomeFlowsOrder.lastPlayed.sorted(try await discoverPlaylists(), lastPlayed: flowPlays)
    }

    /// D299: the name under another user's flow on Home's Your flows (and " · sam" in the car): D205's caption, only
    /// while everyone's flows show, never the user's own or an ownerless one.
    func homeFlowCaption(playlistId: String) -> String? { discoverOwnerCaption(playlistId: playlistId) }

    /// D300: Settings › CarPlay › Flows with your playlists, while Aurral is set up.
    var carFlowsWithPlaylists: Bool { preferences.carPlay.flowsWithPlaylists && aurralSetUp }

    /// D300: the car's Playlists with Flows with your playlists on: `playlists` and `flows` together A to Z, another
    /// user's flow named by its Aurral owner (D299), the user's own naming nobody (`CarPlayRows.playlistsWithFlows`).
    func carPlaylistsWithFlows(_ playlists: [Playlist], flows: [Playlist]) -> [Playlist] {
        let captions = Dictionary(flows.compactMap { flow in homeFlowCaption(playlistId: flow.id).map { (flow.id, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        return CarPlayRows.playlistsWithFlows(playlists, flows: flows, captions: captions, signedInUser: session?.username)
    }

    /// The car's Playlists offline (D185, D300): the downloaded playlists Playlists lists (`leavesOutOfPlaylists`), and
    /// with `combined`, the downloaded Discover playlists Discover shows too.
    func carOfflinePlaylists(_ downloaded: [Playlist], combined: Bool) -> [Playlist] {
        let listed = downloaded.filter { !leavesOutOfPlaylists($0) }
        guard combined else { return listed }
        return carPlaylistsWithFlows(listed, flows: downloaded.filter { isDiscoverPlaylist($0) && isShownInDiscover($0) })
    }
}
