import AurralKit
import Foundation
import MagpieCore
import NavidromeKit
import Playback

/// Round 14 A4 (D91, fix round 1, owner): Trending for the owner's chart country (Settings › Home & Library › Charts
/// country), wherever they are. Aurral's own charts are its server's region. For another country, Top songs are Deezer's
/// "Top <Country>" playlist read **through Aurral** (`GET /api/discover/editorial/<id>`, Aurral reads any Deezer
/// playlist); the phone never calls Deezer or Apple. If that read fails, the server's chart shows with "Showing <region>
/// charts". Top albums exist only for the server's region and say so when it differs; artists and genre charts are
/// worldwide.
extension AppModel {
    /// The country whose top songs to show and its chart playlist (nil: the server's own chart).
    nonisolated static func chartTarget(_ setting: ChartsCountry, phoneRegion: String?, serverRegion: String?,
                                        charts: [String: String]) -> (region: String?, playlistId: String?) {
        let server = serverRegion?.uppercased()
        let wanted: String?
        switch setting {
        case .server: wanted = nil
        case .country(let code): wanted = code.uppercased()
        case .automatic: wanted = phoneRegion.map { $0.uppercased() }.flatMap { charts[$0] == nil ? nil : $0 }
        }
        guard let wanted, wanted != server, let id = charts[wanted] else { return (server, nil) }
        return (wanted, id)
    }

    /// Reads Aurral's charts, with the chosen country's top songs (through Aurral) when it isn't the server's.
    func loadTrending(client: AurralClient) async throws -> TrendingSnapshot {
        let trending = try await client.trending()
        var snapshot = TrendingSnapshot(trending)
        let server = trending.region?.uppercased()
        snapshot.songsRegion = server
        snapshot.forSetting = preferences.layout.chartsCountry.stored
        let target = Self.chartTarget(preferences.layout.chartsCountry, phoneRegion: aurralFeeds.phoneRegion(),
                                      serverRegion: server, charts: AurralFeeds.chartPlaylists)
        guard let id = target.playlistId, let region = target.region else { return snapshot }
        do {
            let chart = try await client.editorialPlaylist(id)
            guard !chart.tracks.isEmpty else { throw AurralError.notFound }
            snapshot.songs = chart.tracks.prefix(100).enumerated().map { index, song in
                var s = ChartSong(song)
                s.position = index + 1
                s.movement = nil
                return s
            }
            snapshot.songsRegion = region
            snapshot.chartName = chart.name
            snapshot.chartPlaylistId = id
            snapshot.libraryPlaylistId = chart.libraryPlaylistId
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
