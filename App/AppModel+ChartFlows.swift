import AurralKit
import Foundation
import MagpieCore

/// One of Trending's charts as read (round 15 C2, D132): its name, its songs (chart order, positions 1…), and for a
/// country's or the worldwide chart the Deezer playlist it is (read through the server).
struct ChartPage: Codable, Equatable, Sendable {
    var chart: TrendingChart
    var name: String
    var songs: [ChartSong]
    var playlistId: String?
    var libraryPlaylistId: String?
}

/// Round 15 C2 (owner items 5 and 5b, D130–D134): Trending's chart picker and each chart's own flow.
///
/// - The charts: Worldwide and each country in the bundled `ChartPlaylists.json` (Deezer's "Top <Country>" playlists,
///   read through the server: `GET /api/discover/editorial/<id>`), and the server's genre charts
///   (`GET /api/discover/trending/genres/<id>`). Nothing is asked of Deezer or Apple. Without Aurral there are no
///   charts, so Trending stays hidden as before.
/// - The default chart is the Charts country setting; Trending opens on it and "Make default" sets it.
/// - A chart flow is the user's own Aurral playlist holding the chart's top N (D130/D131): Create flow…, then Edit flow
///   (Songs: N, Refresh now, Remove flow). Each only on the owner's tap and only with accessFlow; Aurral downloads,
///   matches and publishes it to Navidrome. Magpie keeps each chart's flow (its playlist and N) per Navidrome account
///   and Aurral user with Discover's feeds (removed on sign-out).
extension AppModel {
    // MARK: - Reading a chart

    /// Reads `chart` through the server: a country's or the worldwide chart is its Deezer playlist (the editorial
    /// read), a genre's is the server's genre chart. `notFound` when there is no such chart (or it isn't ready).
    func readChart(_ chart: TrendingChart, client: AurralClient) async throws -> ChartPage {
        switch chart {
        case .worldwide, .country:
            let id: String? = switch chart {
            case .worldwide: AurralFeeds.worldwideChartPlaylist
            case .country(let code): AurralFeeds.chartPlaylists[code.uppercased()]
            case .genre: nil
            }
            guard let id else { throw AurralError.notFound }
            let p = try await client.editorialPlaylist(id)
            guard !p.tracks.isEmpty else { throw AurralError.notFound }
            songActions.remember(p.tracks)   // their previews may match a ListenBrainz song (round 14 A3)
            return ChartPage(chart: chart, name: p.name, songs: Self.ranked(p.tracks), playlistId: id,
                             libraryPlaylistId: p.libraryPlaylistId)
        case .genre(let genreId):
            guard let g = try await client.trendingGenre(genreId), !g.items.isEmpty else { throw AurralError.notFound }
            songActions.remember(g.items)
            return ChartPage(chart: chart, name: g.name, songs: Self.ranked(g.items), playlistId: nil, libraryPlaylistId: nil)
        }
    }

    /// The chart's songs in order, numbered from 1 (at most 100).
    nonisolated static func ranked(_ songs: [AurralSong]) -> [ChartSong] {
        songs.prefix(ChartFlowPlan.maxSongs).enumerated().map { index, song in
            var s = ChartSong(song)
            s.position = index + 1
            s.movement = nil
            return s
        }
    }

    /// A chart picked on Trending: the default's songs as the feed holds them, another's as read this session, else
    /// read now (`fresh`: read again anyway).
    func chartPage(_ chart: TrendingChart, fresh: Bool = false) async throws -> ChartPage {
        if !fresh, let t = aurralFeeds.trending, t.chart == chart, let songs = t.songs, !songs.isEmpty {
            return ChartPage(chart: chart, name: t.chartName ?? chartTitle(chart), songs: songs, playlistId: t.chartPlaylistId,
                             libraryPlaylistId: t.libraryPlaylistId)
        }
        if !fresh, let page = aurralFeeds.chartPages[chart.key] { return page }
        guard let client = aurralClient, !isOffline else { throw AurralError.signInNeeded }
        do {
            let page = try await readChart(chart, client: client)
            aurralFeeds.noteChartPage(page, for: chart)
            return page
        } catch {
            noteAurralError(error)
            throw error
        }
    }

    /// A chart's name in the phone's language: "Worldwide", the country's name, or the genre's.
    func chartTitle(_ chart: TrendingChart) -> String {
        switch chart {
        case .worldwide: DiscoverPagesCopy.worldwide
        case .country(let code): DiscoverPagesCopy.regionName(code)
        case .genre(let id):
            aurralFeeds.trending?.genres.first { $0.id == id }?.name ?? aurralFeeds.chartPages[chart.key]?.name
                ?? DiscoverPagesCopy.genreChart
        }
    }

    /// The charts Trending offers: Worldwide, every country with a chart (by name), and the server's genre charts.
    var trendingCharts: (worldwide: Bool, countries: [(code: String, name: String)], genres: [GenreTile]) {
        let countries = AurralFeeds.chartPlaylists.keys.map { ($0, DiscoverPagesCopy.regionName($0)) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        return (AurralFeeds.worldwideChartPlaylist != nil, countries, aurralFeeds.trending?.genres ?? [])
    }

    /// Make default: Trending opens on `chart` from now on (the Charts country setting); Trending reads it at once.
    func makeDefaultChart(_ chart: TrendingChart) async {
        updatePreferences { $0.layout.chartsCountry = ChartsCountry(chart: chart) }
        await aurralFeeds.refresh(.trending)
        homeFeedSlot?.sectionsChanged([.trending])
    }

    // MARK: - The chart's flow (the owner's taps)

    func chartFlow(for chart: TrendingChart) -> ChartFlow? { aurralFeeds.chartFlows.flow(for: chart.key) }

    /// The playlist name for a chart's flow: the chart's own ("Top Worldwide", "Top Australia"), "Top <genre>".
    nonisolated static func chartFlowName(_ page: ChartPage) -> String {
        if case .genre = page.chart { return "Top \(page.name)" }
        return page.name
    }

    nonisolated static func flowTracks(_ songs: [ChartSong]) -> [ChartFlowTrack] {
        songs.map { ChartFlowTrack(artistName: $0.artist, trackName: $0.title, albumName: $0.album, durationMs: $0.durationMs) }
    }

    private func chartFlowClient() throws -> AurralClient {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard aurralCanAddFlow, let client = aurralClient else { throw AurralError.notPermitted }
        return client
    }

    /// Create flow: the chart's top `count` songs as a new playlist of the user's on the server. A name the user
    /// already has gets " 2", " 3"… (up to 5 tries).
    @discardableResult
    func createChartFlow(_ page: ChartPage, count: Int) async throws -> ChartFlow {
        let client = try chartFlowClient()
        let tracks = ChartFlowPlan.tracks(from: Self.flowTracks(page.songs), count: count)
        guard !tracks.isEmpty else { throw AurralError.notFound }
        let base = Self.chartFlowName(page)
        var made: (AurralChartFlowCreated, String)?
        for attempt in 1...5 {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            do {
                made = (try await client.createChartFlow(name: name, tracks: tracks), name)
                break
            } catch AurralError.nameTaken {
                continue
            } catch {
                noteAurralError(error)
                throw error
            }
        }
        guard let (created, name) = made else { throw AurralError.nameTaken }
        let now = aurralFeeds.now()
        let flow = ChartFlow(chartKey: page.chart.key, playlistId: created.playlistId, name: name, count: tracks.count,
                             createdAt: now, refreshedAt: now)
        aurralFeeds.noteChartFlow(flow)
        afterChartFlowChange()
        return flow
    }

    /// Songs: N: the flow now holds the top `count` of `page` (the songs on screen): the tail goes, or more come.
    @discardableResult
    func resizeChartFlow(_ page: ChartPage, count: Int) async throws -> ChartFlow {
        try await sendChartFlow(page, count: count)
    }

    /// Refresh now: the chart is read again and the flow given its top N as they are now.
    @discardableResult
    func refreshChartFlow(_ chart: TrendingChart) async throws -> ChartFlow {
        guard let flow = chartFlow(for: chart) else { throw AurralError.notFound }
        _ = try chartFlowClient()
        let page = try await chartPage(chart, fresh: true)
        if aurralFeeds.trending?.chart == chart { await aurralFeeds.refresh(.trending, force: true) }
        return try await sendChartFlow(page, count: flow.count)
    }

    private func sendChartFlow(_ page: ChartPage, count: Int) async throws -> ChartFlow {
        guard var flow = chartFlow(for: page.chart) else { throw AurralError.notFound }
        let client = try chartFlowClient()
        let tracks = ChartFlowPlan.tracks(from: Self.flowTracks(page.songs), count: count)
        guard !tracks.isEmpty else { throw AurralError.notFound }
        do {
            _ = try await client.updateChartFlow(playlistId: flow.playlistId, tracks: tracks)
        } catch AurralError.notFound {
            aurralFeeds.forgetChartFlow(page.chart.key)   // removed on the server: Create flow… again
            throw AurralError.notFound
        } catch {
            noteAurralError(error)
            throw error
        }
        flow.count = tracks.count
        flow.refreshedAt = aurralFeeds.now()
        aurralFeeds.noteChartFlow(flow)
        afterChartFlowChange()
        return flow
    }

    /// Remove flow: the playlist is removed from the server, and the chart has no flow.
    func removeChartFlow(_ chart: TrendingChart) async throws {
        guard let flow = chartFlow(for: chart) else { return }
        let client = try chartFlowClient()
        do { try await client.deleteChartFlow(playlistId: flow.playlistId) } catch {
            noteAurralError(error)
            throw error
        }
        aurralFeeds.forgetChartFlow(chart.key)
        afterChartFlowChange()
    }

    /// Your flows and Home's shelf read again behind the change (the playlist joins, changes or leaves as the server
    /// publishes it).
    private func afterChartFlowChange() {
        Task { [weak self] in
            await self?.refreshDiscover(force: true)
            self?.homeFeedSlot?.sectionsChanged([.discover])
        }
    }
}
