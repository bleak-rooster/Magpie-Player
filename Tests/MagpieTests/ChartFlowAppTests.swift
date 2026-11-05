import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

/// Round 15 C2 (owner items 5 and 5b, D130–D134): Trending's chart picker, the default chart, and each chart's own flow
/// (create with Songs: N, refresh, resize, remove), in the app against StubAurral 2.13 and a mock Navidrome.
@MainActor @Suite(.serialized) final class ChartFlowAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "ChartFlowAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "ChartFlowAppTests.\(UUID().uuidString)"
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

    func model(aurralSetUp: Bool = true) async throws -> AppModel {
        aurral.useAurral213()
        aurral.setSyncedCreationDelay(reads: 0)
        nav.install(on: transport.navidrome)
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), previewTransport: transport, defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        model.aurralFeeds.phoneRegion = { nil }
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if aurralSetUp {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return model
    }

    private var chartWrites: [String] { aurral.asked.filter { $0.contains("/api/playlists/shared-playlists") } }

    // MARK: - The default chart (D132)

    @Test func makingWorldwideTheDefaultOpensTrendingOnIt() async throws {
        let model = try await model()
        defer { model.signOut() }
        await model.aurralFeeds.refresh(.trending, force: true)
        #expect(model.aurralFeeds.trending?.chart == .country("AU"), "the server's region by default")
        let worldwide = try await model.chartPage(.worldwide)
        #expect(worldwide.name == "Top Worldwide" && worldwide.songs.count == 30 && worldwide.songs.first?.position == 1)
        #expect(aurral.asked.contains("GET /api/discover/editorial/\(StubAurralDiscover.worldwideChart)"), "through the server")
        _ = await model.makeDefaultChart(.worldwide)
        #expect(model.preferences.layout.chartsCountry == .worldwide)
        let t = try #require(model.aurralFeeds.trending)
        #expect(t.chart == .worldwide && t.chartName == "Top Worldwide" && t.songs?.count == 30 && t.albumsRegion == "AU")
        #expect(t.forSetting == "worldwide")
        // A genre chart can be the default too.
        _ = await model.makeDefaultChart(.genre(132))
        #expect(model.aurralFeeds.trending?.chart == .genre(132) && model.aurralFeeds.trending?.chartName == "Pop")
        #expect(model.chartTitle(.genre(132)) == "Pop" && model.chartTitle(.worldwide) == "Worldwide")
        let charts = model.trendingCharts
        #expect(charts.worldwide && charts.countries.count > 50 && charts.genres.map(\.id) == [132, 116, 152])
        #expect(!charts.countries.contains { $0.code == "XX" })
        let hosts = Set(transport.navidrome.requests.compactMap { $0.url?.host })
        #expect(hosts == ["192.168.1.2"], "only Navidrome and the server: \(hosts)")
    }

    // MARK: - A chart's flow (D130, D131, D133; fix round I1, I2, M2, M3)

    private var worldRead: String { "GET /api/discover/editorial/\(StubAurralDiscover.worldwideChart)" }

    /// Creates the worldwide flow and lets the server list it (as Trending's state read does).
    private func confirmedWorldwide(_ model: AppModel, count: Int) async throws -> (ChartPage, ChartFlow) {
        let page = try await model.chartPage(.worldwide)
        let flow = try await model.createChartFlow(page, count: count)
        #expect(await model.checkChartFlow(page) == .live(.inYourFlows))
        return (page, try #require(model.chartFlow(for: .worldwide)))
    }

    @Test func createWithTenThenFiveThenTwentyThenRefreshThenRemove() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (page, flow) = try await confirmedWorldwide(model, count: 10)
        #expect(flow.count == 10 && flow.name == "Top Worldwide" && flow.confirmed)
        let id = flow.playlistId
        #expect(aurral.sharedPlaylistSongs(id)?.map(\.title) == (1...10).map { "World Song \($0)" })
        #expect(model.isAddFlowsPlaylist(AurralFlow(id: id, name: "Top Worldwide")), "it joins Your flows")

        // Shorten: the tail's songs go, with their files (I2).
        #expect(try await model.resizeChartFlow(page, count: 5).count == 5)
        #expect(aurral.sharedPlaylistSongs(id)?.map(\.title) == (1...5).map { "World Song \($0)" })
        #expect(aurral.chartFlowDeletedFiles.count == 5, "the five songs' files are deleted")
        // Extend: only the new songs are sent.
        _ = try await model.resizeChartFlow(page, count: 20)
        #expect(aurral.sharedPlaylistSongs(id)?.count == 20 && model.chartFlow(for: .worldwide)?.count == 20)
        // Refresh after the chart moved on three places: three songs leave (files deleted), three come in.
        aurral.setWorldwideChartOffset(3)
        let reads = aurral.asked.filter { $0 == worldRead }.count
        _ = try await model.refreshChartFlow(.worldwide)
        #expect(aurral.asked.filter { $0 == worldRead }.count == reads + 1, "Refresh now reads the chart again")
        #expect(Set(aurral.sharedPlaylistSongs(id)?.map(\.title) ?? []) == Set((4...23).map { "World Song \($0)" }))
        #expect(aurral.chartFlowDeletedFiles.count == 8)
        // Refresh with nothing changed sends nothing.
        let before = chartWrites.count
        _ = try await model.refreshChartFlow(.worldwide)
        #expect(chartWrites.count == before)

        try await model.removeChartFlow(.worldwide)
        #expect(model.chartFlow(for: .worldwide) == nil && aurral.sharedPlaylistSongs(id) == nil)
        let base = "/api/playlists/shared-playlists"
        #expect(chartWrites == ["POST \(base)", "POST \(base)/\(id)/track-removals", "POST \(base)/\(id)/tracks",
                                "POST \(base)/\(id)/track-removals", "POST \(base)/\(id)/tracks", "DELETE \(base)/\(id)"],
                "each write once, on a tap; never a PUT")
        #expect(!aurral.asked.contains { $0.hasPrefix("POST /api/discover/editorial/") }, "never the whole-chart Add flow")
    }

    /// I1: the name is picked free before sending (the user's playlists and flows, as the server lists them), so the
    /// one create the server queues can't fail on it.
    @Test func aFreeNameIsPickedBeforeSending() async throws {
        aurral.addSharedPlaylist(id: "own-1", name: "Top Worldwide", provider: "deezer-playlist", songs: [])
        aurral.setFlows([StubAurral.Flow(id: "flow-x", name: "top worldwide 2")])
        let model = try await model()
        defer { model.signOut() }
        let page = try await model.chartPage(.worldwide)
        let flow = try await model.createChartFlow(page, count: 4)
        #expect(flow.name == "Top Worldwide 3")
        #expect(aurral.chartFlowCreates.map(\.name) == ["Top Worldwide 3"] && aurral.chartFlowCreates.first?.failed == false)
        #expect(await model.checkChartFlow(page) == .live(.inYourFlows))
    }

    /// I1: a creation the server accepted but never made (its worker failed it) ends in "Couldn't create the flow"
    /// once the server's queue is idle and two reads haven't listed it; Retry makes it again.
    @Test func aCreationTheServerNeverMakesSaysSoAndRetries() async throws {
        aurral.setChartFlowCreationFails(true)
        let model = try await model()
        defer { model.signOut() }
        let start = Date()
        model.aurralFeeds.now = { start }
        let page = try await model.chartPage(.worldwide)
        _ = try await model.createChartFlow(page, count: 6)
        model.aurralFeeds.now = { start.addingTimeInterval(AppModel.chartFlowRetryWindow + 1) }
        #expect(await model.checkChartFlow(page) == .settingUp)
        #expect(await model.checkChartFlow(page) == .couldntCreate)
        await #expect(throws: AurralError.self) { _ = try await model.resizeChartFlow(page, count: 3) }
        aurral.setChartFlowCreationFails(false)
        let dropped = try #require(aurral.chartFlowCreates.first?.id)
        let again = try await model.retryChartFlow(page)
        #expect(again.count == 6 && aurral.chartFlowCreates.count == 2)
        #expect(model.aurralFeeds.chartFlows.wasRemoved(dropped), "the dropped create is never taken back")
        #expect(await model.checkChartFlow(page) == .live(.inYourFlows))
        #expect(DiscoverPagesCopy.couldntCreateFlow == "Couldn\u{2019}t create the flow")
    }

    /// Re-review I3: 2.13 queues the delete, so the next status read still lists the removed playlist; it is never
    /// taken back, and Create flow… shows (no Edit flow).
    @Test func aRemovedFlowIsNeverTakenBackWhileItsDeleteIsQueued() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (page, flow) = try await confirmedWorldwide(model, count: 4)
        aurral.setDeleteDelay(reads: 3)   // 2.13's worker deletes the files and tells Navidrome first
        try await model.removeChartFlow(.worldwide)
        #expect(await model.checkChartFlow(page) == nil)   // its status read is the first after the delete
        #expect(model.discover.status?.sharedPlaylists.contains { $0.id == flow.playlistId } == true, "still listed")
        #expect(model.chartFlow(for: .worldwide) == nil, "Create flow… shows, not Edit flow")
        #expect(await model.checkChartFlow(page) == nil)
        // A sign-out forgets the list with the book.
        #expect(model.aurralFeeds.chartFlows.wasRemoved(flow.playlistId))
        model.signOut()
        #expect(!model.aurralFeeds.chartFlows.wasRemoved(flow.playlistId))
    }

    /// Re-review M-b: a failed read of the flow's songs sends nothing.
    @Test func aFailedSongsReadSendsNothing() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (page, _) = try await confirmedWorldwide(model, count: 6)
        let before = chartWrites
        aurral.setDiscoverFailure(500)
        await #expect(throws: AurralError.self) { _ = try await model.resizeChartFlow(page, count: 3) }
        aurral.setDiscoverFailure(nil)
        #expect(chartWrites == before && model.chartFlow(for: .worldwide)?.count == 6)
    }

    /// Re-review M-c: no create when the names can't be read (it might clash), with words that say try again.
    @Test func noCreateWhenTheNamesCantBeRead() async throws {
        let model = try await model()
        defer { model.signOut() }
        let page = try await model.chartPage(.worldwide)
        aurral.setStatusFailure(502)
        await #expect(throws: AurralError.self) { _ = try await model.createChartFlow(page, count: 3) }
        #expect(chartWrites.isEmpty && model.chartFlow(for: .worldwide) == nil)
        aurral.setStatusFailure(nil)
    }

    /// Re-review M-d: 2.13 retries a failed create after 60 s (up to three tries), and a waiting retry isn't counted
    /// in the queue (`getHonkerQueueDepth` counts only `run_at <= now`), so an idle queue says nothing until the
    /// retries had their time.
    @Test func anIdleQueueSaysNothingUntilTheRetriesHadTheirTime() async throws {
        aurral.setChartFlowCreationFails(true)
        let model = try await model()
        defer { model.signOut() }
        let start = Date()
        model.aurralFeeds.now = { start }
        let page = try await model.chartPage(.worldwide)
        _ = try await model.createChartFlow(page, count: 6)
        model.aurralFeeds.now = { start.addingTimeInterval(30) }
        for _ in 0..<3 { #expect(await model.checkChartFlow(page) == .settingUp) }
        model.aurralFeeds.now = { start.addingTimeInterval(AppModel.chartFlowRetryWindow + 1) }
        #expect(await model.checkChartFlow(page) == .settingUp)
        #expect(await model.checkChartFlow(page) == .couldntCreate)
    }

    /// M2: until the server lists the new flow, Songs: N, Refresh now and Remove flow send nothing (the playlist may
    /// still be made after them).
    @Test func nothingIsSentUntilTheServerListsTheFlow() async throws {
        aurral.setSyncedCreationDelay(reads: 5)
        let model = try await model()
        aurral.setSyncedCreationDelay(reads: 5)
        defer { model.signOut() }
        let page = try await model.chartPage(.worldwide)
        _ = try await model.createChartFlow(page, count: 6)
        aurral.setRunning("busy", true)   // the server's queue is still working: not a failure
        #expect(await model.checkChartFlow(page) == .settingUp)
        await #expect(throws: AurralError.self) { _ = try await model.resizeChartFlow(page, count: 3) }
        await #expect(throws: AurralError.self) { _ = try await model.refreshChartFlow(.worldwide) }
        await #expect(throws: AurralError.self) { try await model.removeChartFlow(.worldwide) }
        #expect(chartWrites == ["POST /api/playlists/shared-playlists"])
        #expect(model.chartFlow(for: .worldwide) != nil, "still setting up, not forgotten")
    }

    /// M3: a lost book (a dropped cache file) is rebuilt from the server: a playlist of the user's with source
    /// "Charts" named after the chart.
    @Test func aLostFlowIsFoundAgainOnTheServer() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (page, flow) = try await confirmedWorldwide(model, count: 10)
        model.aurralFeeds.forgetChartFlow("worldwide")
        #expect(model.chartFlow(for: .worldwide) == nil)
        #expect(await model.checkChartFlow(page) == .live(.inYourFlows))
        let found = try #require(model.chartFlow(for: .worldwide))
        #expect(found.playlistId == flow.playlistId && found.count == 10 && found.confirmed)
        #expect(model.isAddFlowsPlaylist({ var f = AurralFlow(id: "other-phone", name: "Top Pop"); f.sourceName = "Charts"; return f }()),
                "a chart flow made on another phone is Discover's too")
    }

    @Test func eachChartKeepsItsOwnFlowAndItLastsARelaunch() async throws {
        let model = try await model()
        await model.aurralFeeds.refresh(.trending, force: true)
        let world = try await model.createChartFlow(try await model.chartPage(.worldwide), count: 10)
        let pop = try await model.createChartFlow(try await model.chartPage(.genre(132)), count: 3)
        let au = try await model.createChartFlow(try await model.chartPage(.country("AU")), count: 2)
        #expect(pop.name == "Top Pop" && au.name == "Top Australia")
        #expect(Set([world.playlistId, pop.playlistId, au.playlistId]).count == 3)
        #expect(model.chartFlow(for: .worldwide)?.count == 10 && model.chartFlow(for: .genre(132))?.count == 3
                && model.chartFlow(for: .country("AU"))?.count == 2)
        let scope = try #require(model.aurralFeedsScope)
        model.aurralFeeds.follow(scope: nil)
        #expect(model.chartFlow(for: .worldwide) == nil)
        model.aurralFeeds.follow(scope: scope)
        #expect(model.chartFlow(for: .worldwide)?.playlistId == world.playlistId && model.chartFlow(for: .genre(132))?.count == 3)
        model.signOut()
        #expect(model.aurralFeeds.chartFlows.flows.isEmpty)
        model.aurralFeeds.follow(scope: scope)
        #expect(model.aurralFeeds.chartFlows.flows.isEmpty, "the saved copy went with the sign-out")
    }

    @Test func aFlowRemovedOnTheServerCanBeCreatedAgain() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (page, flow) = try await confirmedWorldwide(model, count: 3)
        let other = AurralClient(base: aurral.base, session: aurral.signedInSession(), transport: aurral)
        try await other.deleteChartFlow(playlistId: flow.playlistId)
        for _ in 0..<2 { _ = try await other.status() }   // 2.13 queues the delete: it has run after these reads
        await #expect(throws: AurralError.notFound) { _ = try await model.resizeChartFlow(page, count: 4) }
        #expect(model.chartFlow(for: .worldwide) == nil, "Create flow… shows again")
    }

    /// Without accessFlow (or offline) nothing is sent and the control is hidden (the same gate as Add flow).
    @Test func withoutAccessFlowNothingIsSent() async throws {
        aurral.setRole("user", for: StubAurral.defaultUsername)
        let model = try await model()
        defer { model.signOut() }
        #expect(!model.aurralCanAddFlow)
        let page = try await model.chartPage(.worldwide)
        await #expect(throws: AurralError.notPermitted) { _ = try await model.createChartFlow(page, count: 3) }
        #expect(chartWrites.isEmpty)
    }

    /// M4, M5: Home's Trending shelf names the chart; Make default on Automatic says when it pins a country.
    @Test func homeNamesTheChartAndMakeDefaultSaysWhenItPins() async throws {
        let model = try await model()
        defer { model.signOut() }
        await model.aurralFeeds.refresh(.trending, force: true)
        #expect(model.homeTrendingTitle == "Trending \u{00B7} \(DiscoverPagesCopy.regionName("AU"))")
        let pinned = await model.makeDefaultChart(.country("DE"))
        #expect(pinned == DiscoverPagesCopy.pinnedNote(DiscoverPagesCopy.regionName("DE")))
        #expect(await model.makeDefaultChart(.worldwide) == nil, "only from Automatic to a fixed country")
        #expect(model.homeTrendingTitle == "Trending \u{00B7} Worldwide")
    }

    /// The words (owner: "Create flow…", "Edit flow", "Refresh now", "Songs: N"); never the server's name.
    @Test func theWords() {
        #expect(DiscoverPagesCopy.createFlow == "Create flow\u{2026}" && DiscoverPagesCopy.editFlow == "Edit flow")
        #expect(DiscoverPagesCopy.refreshNow == "Refresh now" && DiscoverPagesCopy.flowSongs(10) == "Songs: 10")
        #expect(DiscoverPagesCopy.chartsCountry == "Default chart")   // M5
        #expect(DiscoverPagesCopy.removeFlowNote.contains("unless another of your playlists uses them"))   // M1
        let words = [DiscoverPagesCopy.createFlow, DiscoverPagesCopy.createFlowTitle, DiscoverPagesCopy.editFlow,
                     DiscoverPagesCopy.refreshNow, DiscoverPagesCopy.removeFlow, DiscoverPagesCopy.removeFlowQuestion,
                     DiscoverPagesCopy.removeFlowNote, DiscoverPagesCopy.flowNote("Worldwide", 10), DiscoverPagesCopy.makeDefault,
                     DiscoverPagesCopy.defaultChart, DiscoverPagesCopy.charts, DiscoverPagesCopy.countries, DiscoverPagesCopy.genres,
                     DiscoverPagesCopy.chooseChart("Worldwide"), DiscoverPagesCopy.topSongs(chart: "Pop"),
                     DiscoverPagesCopy.couldntCreateFlow, DiscoverPagesCopy.editFlowNote, DiscoverPagesCopy.chartsCountry,
                     DiscoverPagesCopy.pinnedNote("Germany")]
        for word in words {
            for name in ["Aurral", "Lidarr", "Navidrome", "Deezer"] { #expect(!word.localizedCaseInsensitiveContains(name), "\(word)") }
        }
    }
}
