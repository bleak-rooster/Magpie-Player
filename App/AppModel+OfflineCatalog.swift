import Foundation
import MagpieCore
import Playback

/// Round 28 O2 (owner, 2026-11-15): what's on the phone, moved here from `AppModel+Offline.swift` (plan §4).
extension AppModel {
    // MARK: - What's on the phone

    /// What's on the phone now (empty when signed out).
    var offlineCatalog: OfflineCatalog {
        get async {
            guard let store = downloads?.store else { return OfflineCatalog(entries: [], playlists: []) }
            return OfflineCatalog(entries: await store.entries(), playlists: await store.playlists())
        }
    }

    /// Where the cover saved with a download is (one per album or playlist), shown before asking the server. Not
    /// checked here: the caller reads it off the main actor, and a missing file reads as no image.
    func localCoverURL(_ coverArtId: String?) -> URL? {
        guard let coverArtId, let store = downloads?.store else { return nil }
        return store.coverPath(coverArtId: coverArtId)
    }

    /// The lock screen's artwork: offline only a cover saved on the phone (none if it isn't), online the server's.
    func nowPlayingArtworkURL(_ song: Song) -> URL? {
        isOffline ? localCoverURL(song.coverArtId) : coverArtURL(song.coverArtId, size: 600)
    }

    /// What offline pages load again on: the mode, and offline the songs on the phone (the store may only become
    /// readable after first unlock).
    var offlinePageKey: String { isOffline ? "offline|\(downloads?.localFiles.count ?? 0)" : "online" }
}
