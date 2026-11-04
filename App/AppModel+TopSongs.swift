import AurralKit
import Foundation
import ListenBrainzKit
import MagpieCore
import Search

/// One row of an artist's Top songs: the library's song (plays in full), or a song from outside with its preview (when
/// the server can preview it) and, when the library turns out to have it, the library's copy.
struct TopSongRow: Identifiable, Equatable {
    var id: Int
    var song: OutsideSong
    var library: Song?
    var preview: AurralSong?
}

/// An artist's Top songs as read: where they came from, and whether the chosen source had none (the small note).
struct TopSongsResult: Equatable {
    var provider: TopSongsProvider
    var rows: [TopSongRow]
    var fellBack: Bool
}

/// Round 14 A3 (owner answer 6, D104): every artist page's Top songs (in the library and outside it) from the source
/// chosen in Settings › Home & Library › Artist top songs, falling back in Automatic's order (the server, ListenBrainz,
/// the library) when it fails or has none. A source the setup lacks is skipped (owner answer 9): the server needs
/// Aurral 2.13 with artist previews and the artist's MBID; ListenBrainz needs a token and the MBID.
extension AppModel {
    static let topSongsShown = 5

    /// The sources this setup can use for an artist.
    func topSongsProviders(mbid: MBID?) -> Set<TopSongsProvider> {
        var set: Set<TopSongsProvider> = [.library]
        guard !isOffline, mbid != nil else { return set }
        if previewsAvailable, aurralCapabilities.artistPreview { set.insert(.aurral) }
        if hasListenBrainzToken { set.insert(.listenBrainz) }
        return set
    }

    /// Top songs for an artist page. Nil when no source had any (the row hides).
    func artistTopSongs(name: String, mbid: MBID?) async -> TopSongsResult? {
        let chosen = preferences.layout.artistTopSongs
        let order = TopSongsPlan.order(chosen, available: topSongsProviders(mbid: mbid))
        guard let got = await TopSongsPlan.load(order, read: { provider in
            try await self.readTopSongs(provider, name: name, mbid: mbid)
        }) else { return nil }
        return TopSongsResult(provider: got.provider, rows: got.rows,
                              fellBack: TopSongsPlan.fellBack(chosen: chosen, used: got.provider, order: order))
    }

    private func readTopSongs(_ provider: TopSongsProvider, name: String, mbid: MBID?) async throws -> [TopSongRow] {
        let limit = Self.topSongsShown
        switch provider {
        case .library:
            let songs = try await request { try await $0.topSongs(artistName: name) }
            return songs.prefix(limit).enumerated().map { i, s in
                TopSongRow(id: i, song: OutsideSong(title: s.title, artist: s.artist, album: s.album, duration: s.duration,
                                                    recordingMBID: s.recordingMBID),
                           library: s, preview: nil)
            }
        case .aurral:
            guard let mbid else { return [] }
            let songs = Array(await artistPreviewSongs(mbid, artistName: name).prefix(limit))
            let copies = await libraryCopies(of: songs.map(ChartSong.init))
            return songs.enumerated().map { i, a in
                var s = OutsideSong(a)
                s.artistMBID = mbid
                return TopSongRow(id: i, song: s, library: copies[i], preview: a.preview == nil ? nil : a)
            }
        case .listenBrainz:
            guard let mbid else { return [] }
            let client = ListenBrainzClient(transport: transport, token: tokenStore.load(), limiter: listenBrainzLimiter)
            let recordings = try await client.topRecordingsForArtist(mbid, limit: limit)
            var rows: [TopSongRow] = []
            for (i, r) in recordings.enumerated() {
                rows.append(TopSongRow(id: i, song: OutsideSong(r), library: await librarySong(for: r),
                                       preview: await previewSong(for: r)))
            }
            return rows
        }
    }
}
