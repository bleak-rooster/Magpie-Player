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
///   Round 24 (D202): "another user's" is the claiming Aurral item's owner (`identifyDiscoverPlaylists`), never a
///   name; a playlist no item could claim (Q1's tie) is treated the same way: listed only under everyone's.
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

    /// Hook from each read of Aurral (`performDiscoverRead`): the matched playlists Discover lists only under everyone's.
    /// Round 24 (D202): decided by the claiming Aurral item's owner (`identifyDiscoverPlaylists`), never by a name.
    func noteOthersPlaylists(_ ids: Set<String>, scope: String) {
        discover.othersPlaylistIds = ids
        appDefaults.set(ids.sorted(), forKey: Self.othersPlaylistsKeyPrefix + scope)
    }
}

/// The words for D190 (Settings › Aurral; §5 voice).
enum EveryonesFlowsCopy {
    static let toggle = "Show everyone\u{2019}s flows and playlists"
    static let footer = "Off: Discover shows only what you made. On: flows and playlists anyone on your server made appear too."
}
