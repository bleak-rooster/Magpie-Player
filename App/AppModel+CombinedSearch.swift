import AurralKit
import Foundation
import ListenBrainzKit
import MagpieCore
import Search

/// Round 14 A5 (owner answer 5, D95–D99): which outside sources Search has in each setup.
/// - Navidrome only: the library only.
/// - With Lidarr: its artists and albums, and the songs on its albums' tracklists (MusicBrainz, through the app's one
///   rate-limited client and the session's OutsideCatalog); ListenBrainz's song search when Lidarr has no album hit.
/// - With Aurral 2.13 (its `search` capability, read fresh): its artists and albums too, paged for Load more.
/// - All three: merged, one row per MBID. Offline: none.
extension AppModel {
    func outsideSearchSources(sourceTimeout: Duration) -> ([MergedSearch.Source], MergedSearch.OutsideMore) {
        guard !isOffline else { return ([], MergedSearch.OutsideMore()) }   // Task 14
        var sources: [MergedSearch.Source] = []
        var more = MergedSearch.OutsideMore()
        if aurralCapabilities.search, let aurral = aurralClient {
            sources.append(.aurral(aurral, timeout: sourceTimeout))
            more = .aurral(aurral)
        }
        if let lidarr = lidarrClient {
            let shared = SharedOutsideSearch(lidarr: lidarr, timeout: sourceTimeout)
            let catalog = outsideCatalog
            let tracklists = TracklistSongs(release: { try await catalog.release(releaseGroup: $0) })
            // A9: the token only ever goes to api.listenbrainz.org; the client never sends it to labs.
            let listenBrainz = ListenBrainzClient(transport: transport, token: tokenStore.load(),
                                                  clientVersion: Self.marketingVersion)
            sources.append(.lidarr(shared, timeout: sourceTimeout))
            if sourceTimeout >= MergedSearch.sourceTimeout {
                // The phone: the songs wait for Lidarr's search and then tracklist reads; ListenBrainz is the backup.
                sources.append(.songs(lidarr: shared, tracklists: tracklists,
                                      backup: { try await listenBrainz.searchRecordings($0) }, timeout: MergedSearch.songsTimeout))
            } else {
                // Fix round 1 (I3, Decision 10: CarPlay unchanged this round): on the car's short deadline ListenBrainz's
                // songs run beside the tracklist read, as before, and whichever answers in time shows.
                sources.append(.listenBrainz(listenBrainz, timeout: sourceTimeout))
                sources.append(.songs(lidarr: shared, tracklists: tracklists, backup: nil, timeout: sourceTimeout))
            }
            more.tracklists = tracklists
        }
        return (sources, more)
    }

    /// Search looks beyond the library in this setup (the band's "still looking" line shows only then).
    var searchLooksOutside: Bool {
        !isOffline && (lidarrClient != nil || (aurralCapabilities.search && aurralClient != nil))
    }

    /// An "In your library" row found on an album's tracklist (D96): the library's own song, to play.
    func librarySong(id: String) async -> Song? {
        try? await request { try await $0.song(id: id) }
    }
}
