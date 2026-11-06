import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

/// Aurral on its host, everything else to the Navidrome mock (Lidarr's host too, when connected). Never the internet.
final class Round14Routing: HTTPTransport, @unchecked Sendable {
    let aurral = StubAurral()
    let navidrome = MockTransport()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == aurral.host { return try await aurral.send(request) }
        return try await navidrome.send(request)
    }
}

private let lidarrBase = URL(string: "http://192.168.1.2:8686")!

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
    func model(aurralSetUp: Bool = true, aurral213: Bool = true, signIn: Bool = true, lidarr: Bool = false) async throws -> AppModel {
        if aurral213 { aurral.useAurral213() }
        nav.install(on: transport.navidrome)
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: lidarrBase, apiKey: "dev-key")) }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), previewTransport: transport, defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        model.aurralFeeds.phoneRegion = { nil }   // the simulator's region never picks the chart (chartModel sets one)
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
        #expect(model.aurralFeeds.trending == nil && aurral.requests.isEmpty)
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

    @Test func trendingFollowsTheServersRegionByDefault() async throws {
        let model = try await model()
        model.aurralFeeds.phoneRegion = { nil }
        defer { model.signOut() }
        await model.aurralFeeds.refresh(.trending, force: true)
        let t = try #require(model.aurralFeeds.trending)
        #expect(t.region == "AU" && t.songsRegion == "AU" && t.showingServerInstead == nil)
        #expect(t.songs?.first?.title == "Harbour Lights" && t.daysAtTop == 9)
        #expect(t.songs?[1].movement == .up(3) && t.songs?[3].movement == .new)
        #expect(t.albums?.first?.name == "Wide Open" && t.genres.count == 3)
        #expect(!aurral.asked.contains { $0.hasPrefix("GET /api/discover/editorial/") }, "the server's own chart")
        #expect(t.albumsRegion == nil)
    }

    /// Owner (fix round 1): Charts country. Top songs for a country other than the server's are Deezer's "Top <Country>"
    /// playlist read **through the server** (`/api/discover/editorial/<id>`); the phone never calls Deezer or Apple.
    func chartModel(phone: String?, setting: ChartsCountry = .automatic, server: String = "AU") async throws -> AppModel {
        aurral.setTrendingRegion(server)
        let model = try await model()
        model.aurralFeeds.phoneRegion = { phone }
        model.updatePreferences { $0.layout.chartsCountry = setting }
        await model.aurralFeeds.refresh(.trending, force: true)
        return model
    }

    private var editorialReads: [String] { aurral.asked.filter { $0.hasPrefix("GET /api/discover/editorial/") } }

    @Test func thePhonesRegionWithAChartReadsItThroughTheServer() async throws {
        let model = try await chartModel(phone: "US")
        defer { model.signOut() }
        let t = try #require(model.aurralFeeds.trending)
        #expect(editorialReads == ["GET /api/discover/editorial/1313621735"], "Top USA, through the server")
        #expect(t.songsRegion == "US" && t.chartPlaylistId == "1313621735" && t.showingServerInstead == nil)
        #expect(t.songs?.map(\.position) == [1, 2, 3, 4] && t.songs?.first?.previewId == "3135556")
        #expect(t.albums?.first?.name == "Wide Open" && t.albumsRegion == "AU", "albums only exist for the server's region")
        #expect(DiscoverPagesCopy.topSongs(region: "US") == "Top songs \u{00B7} \(Locale.current.localizedString(forRegionCode: "US")!)")
        #expect(DiscoverPagesCopy.topAlbums(region: "AU") == "Top albums \u{00B7} \(Locale.current.localizedString(forRegionCode: "AU")!)")
        #expect(DiscoverPagesCopy.topAlbums(region: nil) == "Top albums")
        #expect(t.genres.map(\.name) == ["Pop", "Rap/Hip Hop", "Rock"], "genre charts stay the server's, worldwide")
        let hosts = Set(transport.navidrome.requests.compactMap { $0.url?.host })
        #expect(hosts == ["192.168.1.2"], "only Navidrome and the server: \(hosts)")
    }

    @Test func aPhoneRegionWithoutAChartUsesTheServers() async throws {
        let model = try await chartModel(phone: "NZ")
        defer { model.signOut() }
        let t = try #require(model.aurralFeeds.trending)
        #expect(editorialReads.isEmpty && t.songsRegion == "AU" && t.albumsRegion == nil && t.daysAtTop == 9)
        #expect(t.songs?.first?.title == "Harbour Lights" && t.songs?.count == 5)
    }

    @Test func theSameRegionAsTheServerReadsNothingMore() async throws {
        let model = try await chartModel(phone: "AU")
        defer { model.signOut() }
        #expect(editorialReads.isEmpty && model.aurralFeeds.trending?.songsRegion == "AU")
    }

    @Test func aChosenCountryAndTheServersOwn() async throws {
        let model = try await chartModel(phone: "US", setting: .country("DE"))
        defer { model.signOut() }
        #expect(editorialReads == ["GET /api/discover/editorial/1111143121"])
        #expect(model.aurralFeeds.trending?.songsRegion == "DE")
        // Changing the setting reads again at once (the copy was for another country).
        model.updatePreferences { $0.layout.chartsCountry = .server }
        await model.aurralFeeds.refresh(.trending)
        #expect(model.aurralFeeds.trending?.songsRegion == "AU" && editorialReads.count == 1)
        #expect(AurralFeeds.chartPlaylists["JP"] != nil && AurralFeeds.chartPlaylists.count > 50)
    }

    @Test func aCountrysChartThatCantBeReadShowsTheServers() async throws {
        aurral.setEditorialMissing("1313621735")
        let model = try await chartModel(phone: "US")
        defer { model.signOut() }
        let t = try #require(model.aurralFeeds.trending)
        #expect(t.songsRegion == "AU" && t.showingServerInstead == "AU" && t.songs?.first?.title == "Harbour Lights")
        #expect(DiscoverPagesCopy.showingServer(region: "AU") == "Showing \(Locale.current.localizedString(forRegionCode: "AU")!) charts")
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
        #expect(second.aurralSetUp && second.aurralFeeds.has(.recommended))
        #expect(tiles.map(\.title) == ["Harbour Lights", "Paper Moon", "Night Drive", "Southerly"])
        #expect(try await second.aurralFeeds.items(for: .recommended, limit: 20).first?.title == "Stub Arrows")
        // Slow: a read that takes long never holds up a section that has a saved copy, nor For you (3 s at most).
        aurral.setDown(false)
        aurral.setDiscoverDelay(.seconds(30))
        var start = Date()
        #expect(try await second.aurralFeeds.items(for: .trending, limit: 4).count == 4)
        #expect(Date().timeIntervalSince(start) < 1.5, "a saved copy is shown at once while the read goes on")
        start = Date()
        _ = await second.forYouOnHome(limit: 8)
        #expect(Date().timeIntervalSince(start) < 4.5)
    }

    /// I3 ruling: the server's session ending (or the server down) keeps every saved copy and Home section; only an
    /// explicit sign-out in Settings removes them.
    @Test func anEndedSessionKeepsTheCopiesASignOutRemovesThem() async throws {
        let model = try await model()
        defer { model.signOut() }
        _ = try await model.aurralFeeds.items(for: .trending, limit: 4)
        _ = try await model.aurralFeeds.items(for: .recommended, limit: 4)
        aurral.expireAllSessions()
        aurral.setLoginDown(true)
        await model.aurralFeeds.refresh(.trending, force: true)
        #expect(model.aurralSetUp && model.aurralFeeds.failed.contains(.trending))
        #expect(try await model.aurralFeeds.items(for: .trending, limit: 4).count == 4)
        #expect(model.aurralFeeds.availableSections.contains(.recommended) && model.homeOutsideSections.contains(.trending))
        let file = try #require(try FileManager.default.contentsOfDirectory(at: AurralFeeds.directory(root: tmp),
                                                                             includingPropertiesForKeys: nil).first)
        model.disconnectAurral()
        #expect(model.aurralFeeds.trending == nil && model.aurralFeeds.availableSections.isEmpty)
        #expect(model.homeOutsideSections.isEmpty && !FileManager.default.fileExists(atPath: file.path))
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

    private var synced: String { StubAurral.syncedId("908622995") }

    /// Aurral publishes the synced playlist to Navidrome under its name, with the songs it has so far.
    private func publishPicks() {
        nav.addList("pl-ipp", name: "Indie Pop Picks", songs: [
            .init(id: "s-1", title: "Harbour Lights", artist: "Stub Arrows", duration: 196, mbid: nil, library: 2),
            .init(id: "s-2", title: "Paper Moon", artist: "Stub Arrows", duration: 197, mbid: nil, library: 2),
        ])
    }

    @Test func aDiscoverPlaylistsSongsAndAddFlow() async throws {
        aurral.setSyncedCreationDelay(reads: 0)
        let model = try await model()
        defer { model.signOut() }
        let page = try await model.editorialPage(id: "908622995")
        #expect(page.name == "Indie Pop Picks" && page.curator == "Deezer Pop Editor" && page.songs.count == 4)
        #expect(page.libraryPlaylistId == nil)
        #expect(await model.addFlowState(playlistId: nil) == .ready)
        publishPicks()
        let result = try await model.addFlow(deezerPlaylistId: "908622995")
        #expect(result.playlistId == synced && !result.alreadyAdded)
        #expect(aurralWrites == ["POST /api/discover/editorial/908622995/library"], "one write, on the tap")
        #expect(otherWrites.isEmpty, "Magpie sends nothing else for a flow (no Lidarr, no playlist edits)")
        // It joins Your flows, and isn't offered Refresh Flow.
        await model.refreshDiscover(force: true)
        #expect(try await model.discoverPlaylists().map(\.name).contains("Indie Pop Picks"))
        #expect(model.isDiscoverPlaylist(id: "pl-ipp") && model.discoverFlow(playlistId: "pl-ipp") == nil)
        #expect(model.discoverSyncedPlaylist(playlistId: "pl-ipp")?.id == synced)
        // Progress: 2 of 4 in, one downloading, one failed.
        let progress = try #require(await model.syncedProgress(playlistId: synced))
        #expect(progress.total == 4 && progress.done == 2 && progress.failed.count == 1 && progress.waiting == 1)
        #expect(await model.addFlowState(playlistId: synced) == .downloading(done: 2, total: 4))
        // Retry the failed song: the server's re-search.
        try await model.retrySong(playlistId: synced, job: progress.failed[0])
        #expect(aurralWrites.last?.hasSuffix("/research") == true
                && aurralWrites.last?.contains("shared-playlists/\(synced)/tracks/") == true)
        // Every song in: In your flows.
        aurral.setSyncedJobs(to: "done")
        #expect(await model.addFlowState(playlistId: synced) == .inYourFlows)
        // Adding again: Aurral says it's there already; the page knows it's added.
        #expect(try await model.addFlow(deezerPlaylistId: "908622995").alreadyAdded)
        #expect(try await model.editorialPage(id: "908622995").libraryPlaylistId == synced)
    }

    /// I1: Aurral 2.13 queues the playlist's creation. Until it is listed with its songs the page says it is setting
    /// up (never "In your flows"), and keeps asking; then Downloading, then In your flows, and asking stops.
    @Test func addFlowFollowsAQueuedCreation() async throws {
        aurral.setSyncedCreationDelay(reads: 3)
        let model = try await model()
        defer { model.signOut() }
        _ = try await model.addFlow(deezerPlaylistId: "908622995")
        #expect(await model.syncedProgress(playlistId: synced) == nil, "jobs 404 while queued")
        let recorder = PhaseRecorder()
        let stub = aurral
        let follow = Task { @MainActor in
            await model.followAddFlow(playlistId: StubAurral.syncedId("908622995"), every: .milliseconds(20)) {
                recorder.phases.append($0)
                if $0 == .downloading(done: 2, total: 4) { stub.setSyncedJobs(to: "done") }
            }
        }
        await follow.value
        let phases = recorder.phases
        #expect(phases.prefix(2).allSatisfy { $0 == .preparing } && phases.first == .preparing, "\(phases)")
        #expect(!phases.dropLast().contains(.inYourFlows))
        #expect(phases.contains(.downloading(done: 2, total: 4)) && phases.last == .inYourFlows, "\(phases)")
    }

    /// Fix round 2 (N3): once the queued playlist is listed, Your flows (and Home's Discover shelf) are read again, so it
    /// joins without waiting for the next full read.
    @Test func aQueuedPlaylistJoinsYourFlowsOnceListed() async throws {
        aurral.setSyncedCreationDelay(reads: 2)
        publishPicks()
        let model = try await model()
        defer { model.signOut() }
        _ = try await model.addFlow(deezerPlaylistId: "908622995")
        try await waitUntil { model.discover.refreshTask == nil }   // Add flow's own read, before the server created it
        #expect(!model.isDiscoverPlaylist(id: "pl-ipp"))
        let stub = aurral
        await model.followAddFlow(playlistId: synced, every: .milliseconds(20)) { phase in
            if phase == .downloading(done: 2, total: 4) { stub.setSyncedJobs(to: "done") }
        }
        try await waitUntil { model.isDiscoverPlaylist(id: "pl-ipp") }
    }

    /// Fix round 2 (N1): a listed playlist whose songs can't be read says so (with Retry), never "Still setting up",
    /// and keeps being asked.
    @Test func aListedPlaylistWhoseSongsCantBeReadSaysSoAndKeepsAsking() async throws {
        aurral.setSyncedCreationDelay(reads: 0)
        let model = try await model()
        defer { model.signOut() }
        _ = try await model.addFlow(deezerPlaylistId: "908622995")
        aurral.setDiscoverFailure(503)   // the jobs route; the status still answers
        let later = Date().addingTimeInterval(11 * 60)
        model.aurralFeeds.now = { later }
        #expect(await model.addFlowState(playlistId: synced) == .unreadable)
        #expect(AddFlowPhase.unreadable.label == "Couldn\u{2019}t check the download just now.")
        let recorder = PhaseRecorder()
        let stub = aurral
        await model.followAddFlow(playlistId: synced, every: .milliseconds(10)) { phase in
            recorder.phases.append(phase)
            if recorder.phases.count == 3 { stub.setDiscoverFailure(nil); stub.setSyncedJobs(to: "done") }
        }
        #expect(recorder.phases.prefix(3) == [.unreadable, .unreadable, .unreadable] && recorder.phases.last == .inYourFlows)
    }

    /// Fix round 2 (N4): an already-added playlist's page starts from nothing, never a "Setting up…" flash.
    @Test func anAddedPlaylistNeverFlashesSettingUp() {
        #expect(AddFlowControl.shown(adding: false, playlistId: "x", canAdd: true, phase: nil) == nil)
        #expect(AddFlowControl.shown(adding: false, playlistId: nil, canAdd: true, phase: nil) == .ready)
        #expect(AddFlowControl.shown(adding: true, playlistId: "x", canAdd: true, phase: .inYourFlows) == .adding)
        #expect(AddFlowControl.shown(adding: false, playlistId: "x", canAdd: false, phase: .inYourFlows) == nil)
    }

    /// Fix round 2 (N2): no empty region name.
    @Test func anUnknownServerRegionIsNamedPlainly() async throws {
        aurral.setEditorialMissing("1313621735")
        let model = try await chartModel(phone: "US", server: "")
        defer { model.signOut() }
        let t = try #require(model.aurralFeeds.trending)
        #expect(DiscoverPagesCopy.showingServer(region: t.showingServerInstead) == "Showing your server\u{2019}s charts")
        #expect(DiscoverPagesCopy.showingServer(region: "") == "Showing your server\u{2019}s charts")
        #expect(DiscoverPagesCopy.topSongs(region: "") == "Top songs" && DiscoverPagesCopy.topAlbums(region: "") == "Top albums")
    }

    /// I1: still not there after 10 minutes: "Still setting up", and asking stops.
    @Test func aCreationThatNeverRunsStopsAsking() async throws {
        aurral.setSyncedCreationDelay(reads: 1_000)
        let model = try await model()
        defer { model.signOut() }
        _ = try await model.addFlow(deezerPlaylistId: "908622995")
        #expect(await model.addFlowState(playlistId: synced) == .preparing)
        let later = Date().addingTimeInterval(11 * 60)
        model.aurralFeeds.now = { later }
        #expect(await model.addFlowState(playlistId: synced) == .stillSettingUp)
        let recorder = PhaseRecorder()
        await model.followAddFlow(playlistId: synced, every: .milliseconds(5)) { recorder.phases.append($0) }
        #expect(recorder.phases == [.stillSettingUp])
        #expect(AddFlowPhase.stillSettingUp.label == "Still setting up. Check back later.")
    }

    /// Round 22 R22A (D183, supersedes I2's "only Add flow's"): every one of the user's shared playlists is Discover's,
    /// a Spotify import and one made by hand in Aurral as well as Add flow's.
    @Test func everySharedPlaylistJoinsDiscover() async throws {
        let songs: [(title: String, artist: String, durationMs: Int)] = [("Harbour Lights", "Stub Arrows", 196_000),
                                                                         ("Paper Moon", "Stub Arrows", 197_000)]
        aurral.addSharedPlaylist(id: "6c1e0000-0000-4000-8000-000000000001", name: "Road Mix", provider: "spotify-playlist", songs: songs)
        aurral.addSharedPlaylist(id: "6c1e0000-0000-4000-8000-000000000002", name: "Made By Hand", provider: nil, songs: songs)
        aurral.addSharedPlaylist(id: "6c1e0000-0000-4000-8000-000000000003", name: "Other Phone Picks",
                                 provider: "deezer-playlist", songs: songs)
        for (id, name) in [("pl-road-mix", "Road Mix"), ("pl-hand", "Made By Hand"), ("pl-other", "Other Phone Picks")] {
            nav.addList(id, name: name, songs: [
                .init(id: "\(id)-1", title: "Harbour Lights", artist: "Stub Arrows", duration: 196, mbid: nil, library: 2),
                .init(id: "\(id)-2", title: "Paper Moon", artist: "Stub Arrows", duration: 197, mbid: nil, library: 2),
            ])
        }
        let model = try await model()
        defer { model.signOut() }
        await model.refreshDiscover(force: true)
        let names = try await model.discoverPlaylists().map(\.name)
        #expect(names.contains("Other Phone Picks"), "Add flow's from another phone (a Deezer playlist)")
        #expect(names.contains("Road Mix") && names.contains("Made By Hand"))
        #expect(model.isDiscoverPlaylist(id: "pl-road-mix") && model.isDiscoverPlaylist(id: "pl-hand"))
        #expect(try await !model.libraryPlaylists().contains { ["pl-road-mix", "pl-hand"].contains($0.id) })
    }

    /// Owner answer 10: with Lidarr connected, Add flow still sends nothing to Lidarr.
    @Test func addFlowWithLidarrConnectedSendsNothingToLidarr() async throws {
        aurral.setSyncedCreationDelay(reads: 0)
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        #expect(model.lidarr != nil)
        _ = try await model.addFlow(deezerPlaylistId: "908622995")
        _ = await model.addFlowState(playlistId: synced)
        let toLidarr = transport.navidrome.requests.filter { $0.url?.port == 8686 && ($0.httpMethod ?? "GET") != "GET" }
        #expect(toLidarr.isEmpty && otherWrites.isEmpty)
    }

    @Test func withoutADownloaderTheFlowWaits() async throws {
        aurral.setDownloadSources(configured: false)
        aurral.setSyncedCreationDelay(reads: 0)
        let model = try await model()
        defer { model.signOut() }
        #expect(model.aurralHasDownloader == false)
        _ = try await model.addFlow(deezerPlaylistId: "908622995")
        #expect(await model.addFlowState(playlistId: synced) == .waitingForDownloader)
        #expect(DiscoverPagesCopy.noDownloader.hasPrefix("Songs already in your library will appear"))
        #expect(AddFlowPhase.waitingForDownloader.symbol != AddFlowPhase.downloading(done: 0, total: 1).symbol)
    }

    @Test func withoutAccessFlowAddFlowIsHiddenAndNeverSent() async throws {
        aurral.setRole("user", for: StubAurral.defaultUsername)
        aurral.setPermissions(AurralPermissions(accessFlow: false, addArtist: true, addAlbum: true), for: StubAurral.defaultUsername)
        let model = try await model()
        defer { model.signOut() }
        #expect(!model.aurralCanAddFlow)
        #expect(await model.addFlowState(playlistId: nil) == .hidden)
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
                     DiscoverPagesCopy.notReady, DiscoverPagesCopy.couldntUpdate, DiscoverPagesCopy.settingUp, DiscoverPagesCopy.stillSettingUp, DiscoverPagesCopy.chartsCountry, DiscoverPagesCopy.chartsAutomatic, DiscoverPagesCopy.chartsAutomaticNote, DiscoverPagesCopy.chartsServer, DiscoverPagesCopy.showingServer(region: "DE"), DiscoverPagesCopy.topSongs(region: "JP"),
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

@MainActor final class PhaseRecorder { var phases: [AddFlowPhase] = [] }
