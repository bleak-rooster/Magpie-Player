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
/// - A chart flow is the user's own Aurral playlist holding the chart's top N (D130/D131, fix round): Create flow…
///   under a free name, followed until the server lists it (else Couldn't create the flow, Retry); then Edit flow
///   (Songs: N, Refresh now, Remove flow), each sending only the songs that leave (with their files) and come in. Each only on the owner's tap and only with accessFlow; Aurral downloads,
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

    /// Make default: Trending opens on `chart` from now on (the Default chart setting); Trending reads it at once.
    /// Fix round M5: when the setting was Automatic (following the phone's region) and `chart` is a fixed country, the
    /// note saying Trending now stays on it (nil otherwise).
    @discardableResult
    func makeDefaultChart(_ chart: TrendingChart) async -> String? {
        let wasAutomatic = preferences.layout.chartsCountry == .automatic
        updatePreferences { $0.layout.chartsCountry = ChartsCountry(chart: chart) }
        await aurralFeeds.refresh(.trending)
        homeFeedSlot?.sectionsChanged([.trending])
        guard wasAutomatic, case .country = chart else { return nil }
        return DiscoverPagesCopy.pinnedNote(chartTitle(chart))
    }

    /// Fix round M4: Home's Trending shelf names its chart ("Trending · Worldwide").
    var homeTrendingTitle: String {
        guard let chart = aurralFeeds?.trending?.chart else { return HomeSection.trending.title }
        return "\(HomeSection.trending.title) \u{00B7} \(chartTitle(chart))"
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

    /// The names the user's playlists and flows have on the server now (fix round I1: a create with one of them would
    /// be accepted, then fail in the server's worker).
    private func takenFlowNames() async -> [String] {
        await refreshDiscoverStatus()
        let status = discover.status
        return (status?.flows ?? []).map(\.name) + (status?.sharedPlaylists ?? []).map(\.name)
            + aurralFeeds.chartFlows.flows.map(\.name)
    }

    /// Create flow: the chart's top `count` songs as a new playlist of the user's on the server, under the first free
    /// name ("Top Worldwide", else "Top Worldwide 2"…), sent once. The server queues it; `checkChartFlow` follows it.
    @discardableResult
    func createChartFlow(_ page: ChartPage, count: Int) async throws -> ChartFlow {
        let client = try chartFlowClient()
        let tracks = ChartFlowPlan.tracks(from: Self.flowTracks(page.songs), count: count)
        guard !tracks.isEmpty else { throw AurralError.notFound }
        let name = ChartFlowPlan.freeName(Self.chartFlowName(page), taken: await takenFlowNames())
        let created: AurralChartFlowCreated
        do { created = try await client.createChartFlow(name: name, tracks: tracks) } catch {
            noteAurralError(error)
            throw error
        }
        let now = aurralFeeds.now()
        let flow = ChartFlow(chartKey: page.chart.key, playlistId: created.playlistId, name: name, count: tracks.count,
                             createdAt: now, refreshedAt: now)
        aurralFeeds.noteChartFlow(flow)
        afterChartFlowChange()
        return flow
    }

    /// Couldn't create the flow → Retry: the same N again, under a name picked afresh (anything the server made late
    /// is removed first).
    @discardableResult
    func retryChartFlow(_ page: ChartPage) async throws -> ChartFlow {
        let old = chartFlow(for: page.chart)
        if let old {
            if let client = try? chartFlowClient() { try? await client.deleteChartFlow(playlistId: old.playlistId) }
            aurralFeeds.forgetChartFlow(page.chart.key)
        }
        return try await createChartFlow(page, count: old?.count ?? ChartFlowPlan.defaultCount(chartLength: page.songs.count))
    }

    /// The chart's flow as the server has it now (Trending's state line), or nil when there is none:
    /// - no flow here: one found on the server is taken back (fix round M3: a playlist of the user's with source
    ///   "Charts" named after the chart);
    /// - a flow the server has listed (once is enough: `confirmed`): A4's phase (Downloading 3/10, In your flows…);
    /// - one not listed yet: Setting up…, until the server's queue has been idle for two reads without making it, or
    ///   `addFlowSetUpLimit` passed: then Couldn't create the flow (fix round I1: a create the worker failed).
    func checkChartFlow(_ page: ChartPage) async -> ChartFlowPhase? {
        guard aurralCanAddFlow else { return nil }
        guard let flow = chartFlow(for: page.chart) else {
            return await adoptChartFlow(page) ? await checkChartFlow(page) : nil
        }
        let (phase, listed) = await addFlowRead(playlistId: flow.playlistId)
        if listed {
            aurralFeeds.unlistedIdleReads[flow.playlistId] = nil
            if !flow.confirmed {
                var seen = flow
                seen.confirmed = true
                aurralFeeds.noteChartFlow(seen)
            }
            return .live(phase)
        }
        guard !flow.confirmed else { return .live(phase) }
        if aurralFeeds.now().timeIntervalSince(flow.createdAt) >= Self.addFlowSetUpLimit { return .couldntCreate }
        guard let status = discover.status else { return .settingUp }
        if !status.operationProcessing, status.operationPending == 0 {
            let reads = (aurralFeeds.unlistedIdleReads[flow.playlistId] ?? 0) + 1
            aurralFeeds.unlistedIdleReads[flow.playlistId] = reads
            if reads >= Self.chartFlowIdleReads { return .couldntCreate }
        }
        return .settingUp
    }

    /// Reads with the server's queue idle and the new flow still unlisted before it counts as not made.
    nonisolated static let chartFlowIdleReads = 2

    /// Fix round M3: takes back the chart's flow from the server (a lost book, or a flow made on another phone).
    private func adoptChartFlow(_ page: ChartPage) async -> Bool {
        await refreshDiscoverStatus()
        let base = Self.chartFlowName(page).lowercased()
        func named(_ name: String) -> Bool {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard n.hasPrefix(base) else { return false }
            let rest = n.dropFirst(base.count)
            return rest.isEmpty || (rest.first == " " && rest.dropFirst().allSatisfy(\.isNumber) && rest.count > 1)
        }
        let taken = Set(aurralFeeds.chartFlows.playlistIds)
        guard let found = discover.status?.sharedPlaylists.first(where: {
            $0.sourceName == AurralClient.chartFlowSourceName && named($0.name) && !taken.contains($0.id)
        }) else { return false }
        let now = aurralFeeds.now()
        let count = min(ChartFlowPlan.maxSongs, max(1, found.size ?? ChartFlowPlan.defaultCount(chartLength: page.songs.count)))
        aurralFeeds.noteChartFlow(ChartFlow(chartKey: page.chart.key, playlistId: found.id, name: found.name, count: count,
                                            createdAt: now, refreshedAt: now, confirmed: true))
        return true
    }

    /// Follows the chart's flow while Trending is open: every `every` until it settles (in your flows, couldn't create).
    func followChartFlow(_ page: ChartPage, every: Duration = .seconds(30), onPhase: @MainActor (ChartFlowPhase?) -> Void) async {
        while !Task.isCancelled {
            let phase = await checkChartFlow(page)
            onPhase(phase)
            switch phase {
            case .settingUp?, .live(.preparing)?, .live(.downloading)?, .live(.waitingForDownloader)?, .live(.unreadable)?: break
            default: return
            }
            do { try await Task.sleep(for: every) } catch { return }
        }
    }

    /// Songs: N: the flow now holds the top `count` of `page` (the songs on screen): the songs that leave are taken out
    /// with their files, the ones that come in are added.
    @discardableResult
    func resizeChartFlow(_ page: ChartPage, count: Int) async throws -> ChartFlow {
        try await sendChartFlow(page, count: count)
    }

    /// Refresh now: the chart is read again and the flow given its top N as they are now.
    @discardableResult
    func refreshChartFlow(_ chart: TrendingChart) async throws -> ChartFlow {
        guard let flow = chartFlow(for: chart) else { throw AurralError.notFound }
        guard flow.confirmed else { throw AurralError.runActive }
        _ = try chartFlowClient()
        let page = try await chartPage(chart, fresh: true)
        if aurralFeeds.trending?.chart == chart { await aurralFeeds.refresh(.trending, force: true) }
        return try await sendChartFlow(page, count: flow.count)
    }

    /// Fix round I2: the changes between the flow's songs (its jobs on the server) and the top `count`, sent as one
    /// removal (Aurral deletes the leaving songs' files it alone holds) and one append; nothing when nothing changed.
    private func sendChartFlow(_ page: ChartPage, count: Int) async throws -> ChartFlow {
        guard var flow = chartFlow(for: page.chart) else { throw AurralError.notFound }
        guard flow.confirmed else { throw AurralError.runActive }   // M2: still being made on the server
        let client = try chartFlowClient()
        let tracks = ChartFlowPlan.tracks(from: Self.flowTracks(page.songs), count: count)
        guard !tracks.isEmpty else { throw AurralError.notFound }
        do {
            guard let jobs = try await client.playlistJobs(flow.playlistId) else { throw AurralError.notFound }
            let change = ChartFlowPlan.changes(jobs: jobs, wanted: tracks)
            for batch in stride(from: 0, to: change.remove.count, by: ChartFlowPlan.maxSongs) {
                let ids = Array(change.remove[batch..<min(batch + ChartFlowPlan.maxSongs, change.remove.count)])
                _ = try await client.removeChartFlowSongs(playlistId: flow.playlistId, jobIds: ids)
            }
            if !change.add.isEmpty { _ = try await client.appendChartFlowSongs(playlistId: flow.playlistId, tracks: change.add) }
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

    /// Remove flow: the playlist is removed from the server (with the songs only it brought in), and the chart has no
    /// flow. Not while the server is still making it (M2).
    func removeChartFlow(_ chart: TrendingChart) async throws {
        guard let flow = chartFlow(for: chart) else { return }
        guard flow.confirmed else { throw AurralError.runActive }
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

/// A chart flow's state on Trending (fix round I1): being made on the server, not made (Retry), or A4's phases once
/// the server lists it.
enum ChartFlowPhase: Equatable, Sendable {
    case settingUp
    case couldntCreate
    case live(AddFlowPhase)
}
