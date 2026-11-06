import AurralKit
import Foundation
import MagpieCore

/// Round 23 R23F (owner, 2026-11-07): "I would like to see only my own [flows] but have a toggle to let me see all"
/// (D189, amends D184; D190).
///
/// - Discover (Home, Library › Discover, the car) lists the user's own flows and Aurral playlists. Another user's
///   (Aurral shows an admin everyone's, D184) is still Aurral's: kept out of Playlists, just not listed in Discover.
/// - Settings › Aurral › "Show everyone's flows" (off by default, per account) lists them in Discover too, read-only:
///   they carry no flow id, so no Refresh Flow, Edit flow or Search again, and D186 never starts one.
/// - Either way another user's never shows in Playlists, D188's switch included.
/// - Which matched playlists are another user's is saved per account, so before Aurral answers they stay out too.
extension AppModel {
    nonisolated static let showEveryonesFlowsKeyPrefix = "magpie.showEveryonesFlows."
    nonisolated static let othersPlaylistsKeyPrefix = "magpie.discoverOthersPlaylists."

    /// D190: Settings › Aurral › "Show everyone's flows": off by default, per account.
    var showEveryonesFlows: Bool {
        get {
            guard let scope = navidromeScope else { return false }
            return appDefaults.object(forKey: Self.showEveryonesFlowsKeyPrefix + scope) as? Bool ?? false
        }
        set {
            guard let scope = navidromeScope else { return }
            appDefaults.set(newValue, forKey: Self.showEveryonesFlowsKeyPrefix + scope)
            discover.everyoneRevision += 1   // Library › Discover lists again
            homeFeedSlot?.sectionsChanged([.discover])   // and Home's Discover shelf
        }
    }

    /// D189: the Discover playlists that are other users' flows' or playlists': as last read, else as saved for the
    /// account (before Aurral answers).
    var othersDiscoverPlaylistIds: Set<String> {
        guard aurralSetUp else { return [] }
        if !discover.playlists.isEmpty { return discover.othersPlaylistIds }
        guard let scope = navidromeScope else { return [] }
        return Set(appDefaults.stringArray(forKey: Self.othersPlaylistsKeyPrefix + scope) ?? [])
    }

    func isOthersDiscoverPlaylist(_ playlist: Playlist) -> Bool { othersDiscoverPlaylistIds.contains(playlist.id) }

    /// Whether Discover lists `playlist` (one of its playlists): the user's own always, another user's only with
    /// "Show everyone's flows" on.
    func isShownInDiscover(_ playlist: Playlist) -> Bool { showEveryonesFlows || !isOthersDiscoverPlaylist(playlist) }

    /// Hook from each read of Aurral (`performDiscoverRead`): which matched playlists are another user's.
    func noteOthersPlaylists(_ matched: [DiscoverPlaylist], others: [AurralFlow], scope: String) {
        let ids = Self.othersPlaylistIds(matched, others: others, before: othersDiscoverPlaylistIds)
        discover.othersPlaylistIds = ids
        appDefaults.set(ids.sorted(), forKey: Self.othersPlaylistsKeyPrefix + scope)
    }

    /// Another user's: matched with no flow id (the user's own flows and playlists always have one) and named after one
    /// of `others`, or kept from before (D75's orphan rule) as one with an owner or known another user's. A playlist
    /// of the user's kept without a known flow has neither, so it stays the user's.
    nonisolated static func othersPlaylistIds(_ matched: [DiscoverPlaylist], others: [AurralFlow],
                                              before: Set<String>) -> Set<String> {
        Set(matched.filter { m in
            m.flow.id.isEmpty && (others.contains(m.flow) || m.flow.ownerUserId != nil || m.flow.ownerUsername != nil
                                  || before.contains(m.playlist.id))
        }.map(\.playlist.id))
    }
}

/// The words for D190 (Settings › Aurral; §5 voice).
enum EveryonesFlowsCopy {
    static let toggle = "Show everyone\u{2019}s flows and playlists"
    static let footer = "Off: Discover shows only what you made. On: flows and playlists anyone on your server made appear too."
}
