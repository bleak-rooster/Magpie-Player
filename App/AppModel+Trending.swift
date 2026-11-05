import AurralKit
import Foundation
import MagpieCore
import NavidromeKit
import Playback

/// Round 14 A4 (D91, fix round 1, owner): Trending for the owner's chart country (Settings › Home & Library › Charts
/// country), wherever they are. Round 15 C2 (D132): that setting is Trending's default chart, which may also be the
/// worldwide chart or a genre chart. Aurral's own charts are its server's region. For another country, Top songs are Deezer's
/// "Top <Country>" playlist read **through Aurral** (`GET /api/discover/editorial/<id>`, Aurral reads any Deezer
/// playlist); the phone never calls Deezer or Apple. If that read fails, the server's chart shows with "Showing <region>
/// charts". Top albums exist only for the server's region and say so when it differs; artists and genre charts are
/// worldwide.
extension AppModel {
    /// Reads Aurral's charts, with the default chart's top songs (round 15 C2, D132: a country's or the worldwide chart
    /// through Aurral, or a genre chart) when it isn't the server's own.
    func loadTrending(client: AurralClient) async throws -> TrendingSnapshot {
        let trending = try await client.trending()
        var snapshot = TrendingSnapshot(trending)
        let server = trending.region?.uppercased()
        let setting = preferences.layout.chartsCountry
        snapshot.songsRegion = server
        snapshot.forSetting = setting.stored
        snapshot.chart = server.flatMap { TrendingChart(key: "country:" + $0) }
        let wanted = setting.chart(phoneRegion: aurralFeeds.phoneRegion(), serverRegion: server,
                                   countriesWithCharts: Set(AurralFeeds.chartPlaylists.keys))
        guard let wanted, wanted != snapshot.chart else { return snapshot }
        if case .country(let code) = wanted, AurralFeeds.chartPlaylists[code] == nil { return snapshot }   // no such chart
        do {
            let page = try await readChart(wanted, client: client)
            snapshot.songs = page.songs
            snapshot.chart = wanted
            if case .country(let code) = wanted { snapshot.songsRegion = code } else { snapshot.songsRegion = nil }
            snapshot.chartName = page.name
            snapshot.chartPlaylistId = page.playlistId
            snapshot.libraryPlaylistId = page.libraryPlaylistId
            snapshot.daysAtTop = nil
            snapshot.albumsRegion = server
        } catch {
            snapshot.showingServerInstead = server ?? ""
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
