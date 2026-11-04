import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

/// Aurral on its host, Australia's public charts on theirs, everything else to the Navidrome mock. Never the internet.
final class Round14Routing: HTTPTransport, @unchecked Sendable {
    let aurral = StubAurral()
    let charts = StubPublicCharts()
    let navidrome = MockTransport()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == aurral.host { return try await aurral.send(request) }
        if StubPublicCharts.handles(request) { return try await charts.send(request) }
        return try await navidrome.send(request)
    }
}

/// Round 14 A4 (D90–D94): Trending, Recommended, the Discover playlists and Add flow, end to end in the app against
/// StubAurral 2.13, the public-chart stub and a mock Navidrome, in all four setups.
@MainActor @Suite(.serialized) final class Round14DiscoverTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "Round14DiscoverTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "Round14DiscoverTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = Round14Routing()
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    var aurral: StubAurral { transport.aurral }

    /// Aurral 2.13 (unless `aurral213` is false) and its synced playlist, once added, published to Navidrome.
    func model(aurralSetUp: Bool = true, aurral213: Bool = true, signIn: Bool = true) async throws -> AppModel {
        if aurral213 { aurral.useAurral213() }
        nav.install(on: transport.navidrome)
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), previewTransport: transport, defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        guard signIn else {   // as after a relaunch: the saved session, without waiting for the network
            model.resumeSavedSession()
            return model
        }
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if aurralSetUp {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return model
    }

    /// Aurral's writes to its data (its own login and logout aside).
    private var aurralWrites: [String] { aurral.asked.filter { $0.hasPrefix("POST") && !$0.hasPrefix("POST /api/auth/") } }
    private var otherWrites: [URLRequest] { transport.navidrome.requests.filter { ($0.httpMethod ?? "GET") != "GET" && $0.url?.path.hasSuffix("/auth/login") == false } }

    // MARK: - Setups (owner answer 9)

    @Test func withoutAurralNothingShowsAndNothingIsAsked() async throws {
        let model = try await model(aurralSetUp: false)
        defer { model.signOut() }
        #expect(model.aurralFeeds.availableSections.isEmpty)
        #expect(!model.libraryRows.contains(.trending) && !model.libraryRows.contains(.recommended))
        await model.aurralFeeds.refresh(.trending, force: true)
        #expect(model.aurralFeeds.trending == nil && aurral.requests.isEmpty && transport.charts.requests.isEmpty)
        #expect(await model.forYouOnHome(limit: 8).isEmpty)
    }

    @Test func aurral210KeepsTodaysBehaviour() async throws {
        let model = try await model(aurral213: false)
        defer { model.signOut() }
        #expect(model.aurralFeeds.availableSections.isEmpty)
        #expect(!model.libraryRows.contains(.trending) && model.libraryRows.contains(.discover))
        await model.aurralFeeds.refresh(.recommended, force: true)
        #expect(!aurral.asked.contains("GET /api/discover"))
    }

    @Test func aurral213NamesEverySectionAndBothRows() async throws {
        let model = try await model()
        defer { model.signOut() }
        #expect(model.aurralFeeds.availableSections == Set(HomeSection.recommendedSections + [.trending, .genreCharts, .morePlaylists]))
        #expect(model.libraryRows.suffix(3) == [.discover, .trending, .recommended])
        #expect(!model.libraryRows(carPlay: true).contains(.trending), "CarPlay is unchanged")
    }

    // MARK: - Trending

    @Test func trendingFollowsAurralsRegionWhenItIsAustralia() async throws {
        let model = try await model()
        defer { model.signOut() }
        await model.aurralFeeds.refresh(.trending, force: true)
        let t = try #require(model.aurralFeeds.trending)
        #expect(t.region == "AU" && t.chartName == "Top Australia" && !t.australianFallback)
        #expect(t.songs?.first?.title == "Harbour Lights" && t.daysAtTop == 9)
        #expect(t.songs?[1].movement == .up(3) && t.songs?[3].movement == .new)
        #expect(t.albums?.first?.name == "Wide Open" && t.genres.count == 3)
        #expect(transport.charts.requests.isEmpty, "Aurral's own chart is Australia's: no public chart asked")
    }

    @Test func anotherRegionFallsBackToTopAustralia() async throws {
        aurral.setTrendingRegion("US")
        let model = try await model()
        defer { model.signOut() }
        await model.aurralFeeds.refresh(.trending, force: true)
        let t = try #require(model.aurralFeeds.trending)
        #expect(t.australianFallback && t.chartName == "Top Australia" && t.chartPlaylistId == "1313616925")
        #expect(t.songs?.map(\.title) == ["Bluebottle", "Red Dirt"])
        #expect(t.songs?.first?.previewId == "4100001", "previews still go through Aurral, by Deezer id")
        #expect(t.albums?.first?.name == "Coastline")
        #expect(t.genres.map(\.name) == ["Pop", "Rap/Hip Hop", "Rock"], "genre charts stay the server's, worldwide")
        #expect(transport.charts.requests.allSatisfy { $0.url?.scheme == "https" && $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func aFailingPublicChartKeepsAurralsOwn() async throws {
        aurral.setTrendingRegion("US")
        transport.charts.setStatus(503)
        let model = try await model()
        defer { model.signOut() }
        await model.aurralFeeds.refresh(.trending, force: true)
        let t = try #require(model.aurralFeeds.trending)
        #expect(!t.australianFallback && t.songs?.first?.title == "Harbour Lights")
    }

    @Test func aGenreChartNotReadySaysSo() async throws {
        aurral.setGenreChartReady(116, false)
        let model = try await model()
        defer { model.signOut() }
        await model.aurralFeeds.refreshGenre(132)
        await model.aurralFeeds.refreshGenre(116)
        #expect(model.aurralFeeds.genreCharts[132]?.count == 5)
        #expect(model.aurralFeeds.notReadyGenres == [116] && model.aurralFeeds.genreCharts[116] == nil)
    }

    /// Each section keeps its last copy when a later read doesn't have it (Aurral's chart task failed that part).
    @Test func aMissingSectionKeepsItsLastCopy() async throws {
        let model = try await model()
        defer { model.signOut() }
        await model.aurralFeeds.refresh(.trending, force: true)
        aurral.setTrendingMissing([.albums, .songs])
        await model.aurralFeeds.refresh(.trending, force: true)
        let t = try #require(model.aurralFeeds.trending)
        #expect(t.albums?.first?.name == "Wide Open" && t.songs?.count == 5)
    }

    /// Never loaded and Aurral not ready: the page's sections are nil (they say "updating"), never a failure.
    @Test func neverLoadedSectionsAreUpdating() async throws {
        aurral.setTrendingMissing([.songs, .albums, .artists, .genres])
        let model = try await model()
        defer { model.signOut() }
        await model.aurralFeeds.refresh(.trending, force: true)
        let t = try #require(model.aurralFeeds.trending)
        #expect(t.songs == nil && t.albums == nil && t.artists == nil && t.genres.isEmpty && t.isEmpty)
        #expect(!model.aurralFeeds.failed.contains(.trending))
    }

    // MARK: - Home: never waits, keeps its last copies (round 13)

    @Test func slowOrDownAurralKeepsTheLastTrendingAndRecommended() async throws {
        let first = try await model()
        for section in [HomeSection.trending, .recommended, .becauseYouLike] {
            _ = try await first.aurralFeeds.items(for: section, limit: 20)
        }
        #expect(first.aurralFeeds.trending != nil && first.aurralFeeds.recommended != nil)
        // A relaunch with Aurral down: the saved copies show at once, and the sections are still named.
        aurral.setDown(true)
        let second = try await model(signIn: false)
        defer { second.signOut() }
        try await waitUntil { second.aurralFeeds.trending != nil }
        #expect(second.aurralFeeds.availableSections.contains(.trending))
        #expect(second.aurralFeeds.trending?.songs?.first?.title == "Harbour Lights")
        let tiles = try await second.aurralFeeds.items(for: .trending, limit: 4)
        #expect(tiles.map(\.title) == ["Harbour Lights", "Paper Moon", "Night Drive", "Southerly"])
        #expect(try await second.aurralFeeds.items(for: .recommended, limit: 20).first?.title == "Stub Arrows")
        // Slow: a read that takes long never blocks what is shown.
        aurral.setDown(false)
        aurral.setDiscoverDelay(.seconds(30))
        let start = Date()
        let shelves = await second.forYouOnHome(limit: 8)
        #expect(Date().timeIntervalSince(start) < 10)
        _ = shelves
    }

    @Test func homeTilesFromEachFeed() async throws {
        let model = try await model()
        defer { model.signOut() }
        let feeds = model.aurralFeeds!
        let recommended = try await feeds.items(for: .recommended, limit: 20)
        #expect(recommended.first?.title == "Stub Arrows" && recommended.first?.kind == .artist)
        #expect(feeds.route(for: recommended[0], in: .recommended)
                == .outsideArtist(.init(name: "Stub Arrows", mbid: MBID("a74b1b7f-71a5-4011-9441-d0b5e4122711"))))
        #expect(try await feeds.items(for: .furtherOut, limit: 20).map(\.title) == ["Mallee Fowl", "No Id Band"])
        let charts = try await feeds.items(for: .genreCharts, limit: 20)
        #expect(charts.map(\.title) == ["Pop", "Rap/Hip Hop", "Rock"])
        #expect(feeds.route(for: charts[0], in: .genreCharts) == .genreChart(id: 132, name: "Pop"))
        let songs = try await feeds.items(for: .trending, limit: 2)
        #expect(songs.count == 2 && feeds.route(for: songs[0], in: .trending) == .trending)
        let more = try await feeds.items(for: .morePlaylists, limit: 20)
        #expect(!more.isEmpty && more.allSatisfy { $0.kind == .playlist })
        #expect(feeds.route(for: more[0], in: .morePlaylists) == .discoverPlaylist(id: more[0].key))
        // Your flows ends with the For you playlists.
        #expect(await model.forYouOnHome(limit: 8).map(\.title) == ["Indie Pop Picks", "Dream Pop"])
        #expect(HomeShelf.fits(.outside(more[0]), in: .discover))
        #expect(!HomeShelf.fits(.outside(recommended[0]), in: .discover))
    }

    // MARK: - Recommended: Not for me

    @Test func notForMeHidesAtOnceAndTellsTheServer() async throws {
        let model = try await model()
        defer { model.signOut() }
        let feeds = model.aurralFeeds!
        await feeds.refresh(.recommended, force: true)
        let artist = try #require(feeds.recommended?.artists.first?.artist)
        await feeds.notForMe(artist)
        #expect(!(try await feeds.items(for: .recommended, limit: 20)).contains { $0.title == "Stub Arrows" })
        let write = try #require(aurral.discoverWrites.last)
        #expect(write.0 == "POST /api/discover/feedback")
        #expect(write.1["action"] as? String == "block_artist" && write.1["artistName"] as? String == "Stub Arrows")
        // Kept across a relaunch.
        let again = try await self.model(signIn: false)
        defer { again.signOut() }
        try await waitUntil { again.aurralFeeds.recommended != nil }
        #expect(again.aurralFeeds.hidden.contains(RecommendedRails.key(artist)))
    }

    // MARK: - Discover playlists and Add flow (owner answers 1 and 10)

    @Test func aDiscoverPlaylistsSongsAndAddFlow() async throws {
        let model = try await model()
        defer { model.signOut() }
        let page = try await model.editorialPage(id: "908622995")
        #expect(page.name == "Indie Pop Picks" && page.curator == "Deezer Pop Editor" && page.songs.count == 4)
        #expect(page.libraryPlaylistId == nil)
        #expect(AppModel.addFlowPhase(canAdd: model.aurralCanAddFlow, adding: false, playlistId: nil, progress: nil,
                                      hasDownloader: model.aurralHasDownloader) == .ready)
        // Aurral publishes the synced playlist to Navidrome with the songs it has so far.
        nav.addList("pl-ipp", name: "Indie Pop Picks", songs: [
            .init(id: "s-1", title: "Harbour Lights", artist: "Stub Arrows", duration: 196, mbid: nil, library: 2),
            .init(id: "s-2", title: "Paper Moon", artist: "Stub Arrows", duration: 197, mbid: nil, library: 2),
        ])
        let result = try await model.addFlow(deezerPlaylistId: "908622995")
        #expect(result.playlistId == "static-908622995" && !result.alreadyAdded)
        #expect(aurralWrites == ["POST /api/discover/editorial/908622995/library"], "one write, on the tap")
        #expect(otherWrites.isEmpty, "Magpie sends nothing else for a flow (no Lidarr, no playlist edits)")
        // It joins Your flows, and isn't offered Refresh Flow.
        #expect(try await model.discoverPlaylists().map(\.name).contains("Indie Pop Picks"))
        #expect(model.isDiscoverPlaylist(id: "pl-ipp") && model.discoverFlow(playlistId: "pl-ipp") == nil)
        #expect(model.discoverSyncedPlaylist(playlistId: "pl-ipp")?.id == "static-908622995")
        // Progress: 2 of 4 in, one downloading, one failed.
        let progress = try #require(await model.syncedProgress(playlistId: "static-908622995"))
        #expect(progress.total == 4 && progress.done == 2 && progress.failed.count == 1 && progress.waiting == 1)
        #expect(AppModel.addFlowPhase(canAdd: true, adding: false, playlistId: "static-908622995", progress: progress,
                                      hasDownloader: true) == .downloading(done: 2, total: 4))
        // Retry the failed song: the server's re-search.
        try await model.retrySong(playlistId: "static-908622995", job: progress.failed[0])
        #expect(aurralWrites.last?.hasSuffix("/research") == true && aurralWrites.last?.contains("shared-playlists/static-908622995/tracks/") == true)
        // Every song in: In your flows.
        aurral.setSyncedJobs(to: "done")
        let done = try #require(await model.syncedProgress(playlistId: "static-908622995"))
        #expect(AppModel.addFlowPhase(canAdd: true, adding: false, playlistId: "static-908622995", progress: done,
                                      hasDownloader: true) == .inYourFlows)
        // Adding again: Aurral says it's there already; the page knows it's added.
        #expect(try await model.addFlow(deezerPlaylistId: "908622995").alreadyAdded)
        #expect(try await model.editorialPage(id: "908622995").libraryPlaylistId == "static-908622995")
    }

    @Test func withoutADownloaderTheFlowWaits() async throws {
        aurral.setDownloadSources(configured: false)
        let model = try await model()
        defer { model.signOut() }
        #expect(model.aurralHasDownloader == false)
        _ = try await model.addFlow(deezerPlaylistId: "908622995")
        let progress = try #require(await model.syncedProgress(playlistId: "static-908622995"))
        #expect(AppModel.addFlowPhase(canAdd: true, adding: false, playlistId: "static-908622995", progress: progress,
                                      hasDownloader: model.aurralHasDownloader) == .waitingForDownloader)
        #expect(DiscoverPagesCopy.noDownloader.hasPrefix("Songs already in your library will appear"))
    }

    @Test func withoutAccessFlowAddFlowIsHiddenAndNeverSent() async throws {
        aurral.setRole("user", for: StubAurral.defaultUsername)
        aurral.setPermissions(AurralPermissions(accessFlow: false, addArtist: true, addAlbum: true), for: StubAurral.defaultUsername)
        let model = try await model()
        defer { model.signOut() }
        #expect(!model.aurralCanAddFlow)
        #expect(AppModel.addFlowPhase(canAdd: model.aurralCanAddFlow, adding: false, playlistId: nil, progress: nil,
                                      hasDownloader: true) == .hidden)
        await #expect(throws: AurralError.notPermitted) { try await model.addFlow(deezerPlaylistId: "908622995") }
        #expect(aurralWrites.isEmpty)
        // Reading still works: Recommended and Trending need only a user.
        #expect(try await model.editorialPage(id: "908622995").songs.count == 4)
        await model.aurralFeeds.refresh(.recommended, force: true)
        #expect(model.aurralFeeds.recommended != nil)
    }

    @Test func downloadSongsForAFlowWithAutoDownloadOff() async throws {
        let model = try await model()
        defer { model.signOut() }
        try await model.downloadFlowSongs(flowId: "flow-dw")
        #expect(aurralWrites == ["POST /api/playlists/flows/flow-dw/download"])
        aurral.setDownloadSources(configured: false)
        await #expect(throws: AurralError.noDownloader) { try await model.downloadFlowSongs(flowId: "flow-dw") }
    }

    // MARK: - Words (owner answer 2)

    @Test func noServerNameInTheseScreensWords() {
        let words = [DiscoverPagesCopy.forYou, DiscoverPagesCopy.browseMore, DiscoverPagesCopy.trending,
                     DiscoverPagesCopy.recommended, DiscoverPagesCopy.addFlow, DiscoverPagesCopy.adding,
                     DiscoverPagesCopy.downloading(12, 40), DiscoverPagesCopy.waitingForDownloader, DiscoverPagesCopy.inYourFlows,
                     DiscoverPagesCopy.noDownloaderTitle, DiscoverPagesCopy.noDownloader, DiscoverPagesCopy.couldntDownload,
                     DiscoverPagesCopy.retry, DiscoverPagesCopy.downloadSongs, DiscoverPagesCopy.updating,
                     DiscoverPagesCopy.notReady, DiscoverPagesCopy.couldntUpdate, DiscoverPagesCopy.topAustralia,
                     DiscoverPagesCopy.worldwide, DiscoverPagesCopy.topSongs, DiscoverPagesCopy.topAlbums,
                     DiscoverPagesCopy.topArtists, DiscoverPagesCopy.chartsByGenre, DiscoverPagesCopy.popularPlaylists,
                     DiscoverPagesCopy.topPick, DiscoverPagesCopy.newThisWeek, DiscoverPagesCopy.closeToHome,
                     DiscoverPagesCopy.furtherOut, DiscoverPagesCopy.notForMe, LibraryRow.trending.title,
                     LibraryRow.recommended.title]
        for word in words {
            for name in ["Aurral", "Lidarr", "Navidrome", "Deezer", "Apple"] { #expect(!word.contains(name), "\(word)") }
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

extension DiscoverNavidrome {
    /// Round 14 A4: a playlist Aurral published (its songs in Aurral's library).
    func addList(_ id: String, name: String, songs entries: [Entry]) {
        for e in entries { songs[e.id] = e }
        lists[id] = (name, entries.map(\.id))
    }
}
