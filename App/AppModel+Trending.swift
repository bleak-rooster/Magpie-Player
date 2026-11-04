import AurralKit
import Foundation
import MagpieCore
import NavidromeKit
import Playback

/// Round 14 A4 (D91): Trending. Aurral's charts follow its server's own location; when that isn't Australia, the top
/// songs and top albums come from Australia's public charts instead (Deezer's Top Australia playlist and Apple's AU
/// most-played albums), each on its own: one failing keeps Aurral's for that section. Charts by genre stay Aurral's and
/// are labelled worldwide.
extension AppModel {
    /// The country Trending is for.
    nonisolated static let chartCountry = "AU"

    /// Reads Aurral's charts, with Australia's public charts in place when Aurral's region isn't Australia.
    func loadTrending(client: AurralClient) async throws -> TrendingSnapshot {
        let trending = try await client.trending()
        var snapshot = TrendingSnapshot(trending)
        guard let region = trending.region?.uppercased(), region != Self.chartCountry else { return snapshot }
        let charts = PublicChartsClient(transport: transport)
        async let songs = try? charts.topAustralia()
        async let albums = try? charts.australianAlbums()
        if let songs = await songs, !songs.isEmpty {
            snapshot.songs = songs.map(ChartSong.init)
            snapshot.chartName = DiscoverPagesCopy.topAustralia
            snapshot.chartPlaylistId = PublicChartsClient.topAustraliaPlaylist
            snapshot.libraryPlaylistId = nil
            snapshot.daysAtTop = nil
            snapshot.australianFallback = true
        }
        if let albums = await albums, !albums.isEmpty {
            snapshot.albums = albums.prefix(25).map(ChartAlbum.init)
            snapshot.australianFallback = true
        }
        return snapshot
    }

    /// A chart or Discover playlist song as a preview item (its Deezer id keys it).
    func previewItem(for song: ChartSong) -> PreviewItem { previewItem(for: song.song) }

    // MARK: - In your library

    /// The library's copy of each song that has one (artist + title + duration within 3 s, never by name alone: the
    /// round 12 swap rule, `DiscoverRules.mainCopy`), by the song's index. Each song is looked up once per session.
    func libraryCopies(of songs: [ChartSong]) async -> [Int: Song] {
        guard session != nil, !isOffline else { return [:] }
        var found: [Int: Song] = [:]
        var toLookUp: [(Int, ChartSong)] = []
        for (index, song) in songs.enumerated() {
            let key = Self.chartLookupKey(song)
            if let known = chartLookups[key] { if let copy = known { found[index] = copy } } else { toLookUp.append((index, song)) }
        }
        let excluding = knownAurralSongIds.union(findSongs.map(\.id))
        let libraries = listedLibraryIds.map(Set.init)
        let notLibraries = separateLibraryIds
        await withTaskGroup(of: (Int, String, Song?).self) { group in
            var started = 0
            for (index, song) in toLookUp {
                if started >= 4, let done = await group.next() {
                    chartLookups[done.1] = .some(done.2)
                    if let copy = done.2 { found[done.0] = copy }
                }
                started += 1
                group.addTask { [weak self] in
                    let key = Self.chartLookupKey(song)
                    guard let self, song.duration > 0 else { return (index, key, nil) }
                    let entry = Song(id: "chart-\(key)", title: song.title, artist: song.artist, album: song.album ?? "",
                                     duration: song.duration)
                    let hits = (try? await self.request { try await $0.search(song.title, songCount: 20, albumCount: 0, artistCount: 0) })?.songs ?? []
                    let copy = DiscoverRules.mainCopy(for: entry, recording: nil, mbidMatches: [], textMatches: hits,
                                                      excluding: excluding, libraries: libraries, notLibraries: notLibraries)
                    return (index, key, copy)
                }
            }
            for await done in group {
                chartLookups[done.1] = .some(done.2)
                if let copy = done.2 { found[done.0] = copy }
            }
        }
        return found
    }

    nonisolated static func chartLookupKey(_ song: ChartSong) -> String {
        "\(DiscoverRules.normalised(song.artist))|\(DiscoverRules.normalised(song.title))|\(song.durationMs ?? 0)"
    }

    /// This session's chart song lookups (a hit or a miss), kept with the feeds.
    var chartLookups: [String: Song?] {
        get { aurralFeeds.lookups }
        set { aurralFeeds.lookups = newValue }
    }
}
