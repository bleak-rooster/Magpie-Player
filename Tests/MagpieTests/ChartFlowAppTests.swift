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
        await model.makeDefaultChart(.worldwide)
        #expect(model.preferences.layout.chartsCountry == .worldwide)
        let t = try #require(model.aurralFeeds.trending)
        #expect(t.chart == .worldwide && t.chartName == "Top Worldwide" && t.songs?.count == 30 && t.albumsRegion == "AU")
        #expect(t.forSetting == "worldwide")
        // A genre chart can be the default too.
        await model.makeDefaultChart(.genre(132))
        #expect(model.aurralFeeds.trending?.chart == .genre(132) && model.aurralFeeds.trending?.chartName == "Pop")
        #expect(model.chartTitle(.genre(132)) == "Pop" && model.chartTitle(.worldwide) == "Worldwide")
        let charts = model.trendingCharts
        #expect(charts.worldwide && charts.countries.count > 50 && charts.genres.map(\.id) == [132, 116, 152])
        #expect(!charts.countries.contains { $0.code == "XX" })
        let hosts = Set(transport.navidrome.requests.compactMap { $0.url?.host })
        #expect(hosts == ["192.168.1.2"], "only Navidrome and the server: \(hosts)")
    }

    // MARK: - A chart's flow (D130, D131, D133)

    @Test func createWithTenThenFiveThenRefreshThenRemove() async throws {
        let model = try await model()
        defer { model.signOut() }
        let page = try await model.chartPage(.worldwide)
        #expect(model.chartFlow(for: .worldwide) == nil)
        let flow = try await model.createChartFlow(page, count: 10)
        #expect(flow.count == 10 && flow.name == "Top Worldwide" && flow.chartKey == "worldwide")
        #expect(aurral.sharedPlaylistSongs(flow.playlistId)?.map(\.title) == (1...10).map { "World Song \($0)" })
        #expect(model.chartFlow(for: .worldwide)?.count == 10, "Edit flow shows 10")
        #expect(model.isAddFlowsPlaylist(AurralFlow(id: flow.playlistId, name: "Top Worldwide")), "it joins Your flows")

        let smaller = try await model.resizeChartFlow(page, count: 5)
        #expect(smaller.count == 5 && aurral.sharedPlaylistSongs(flow.playlistId)?.count == 5)
        #expect(aurral.sharedPlaylistSongs(flow.playlistId)?.last?.title == "World Song 5", "the tail went")
        _ = try await model.resizeChartFlow(page, count: 20)
        #expect(aurral.sharedPlaylistSongs(flow.playlistId)?.count == 20 && model.chartFlow(for: .worldwide)?.count == 20)

        let readsBefore = aurral.asked.filter { $0 == "GET /api/discover/editorial/\(StubAurralDiscover.worldwideChart)" }.count
        let refreshed = try await model.refreshChartFlow(.worldwide)
        #expect(refreshed.count == 20 && refreshed.refreshedAt >= flow.refreshedAt)
        #expect(aurral.asked.filter { $0 == "GET /api/discover/editorial/\(StubAurralDiscover.worldwideChart)" }.count == readsBefore + 1,
                "Refresh now reads the chart again")

        try await model.removeChartFlow(.worldwide)
        #expect(model.chartFlow(for: .worldwide) == nil && aurral.sharedPlaylistSongs(flow.playlistId) == nil)
        #expect(chartWrites == ["POST /api/playlists/shared-playlists", "PUT /api/playlists/shared-playlists/\(flow.playlistId)",
                                "PUT /api/playlists/shared-playlists/\(flow.playlistId)",
                                "PUT /api/playlists/shared-playlists/\(flow.playlistId)",
                                "DELETE /api/playlists/shared-playlists/\(flow.playlistId)"], "each write once, on a tap")
        #expect(!aurral.asked.contains { $0.hasPrefix("POST /api/discover/editorial/") }, "never the whole-chart Add flow")
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
        // The same account and Aurral user later: each chart's flow is still there.
        let scope = try #require(model.aurralFeedsScope)
        model.aurralFeeds.follow(scope: nil)
        #expect(model.chartFlow(for: .worldwide) == nil)
        model.aurralFeeds.follow(scope: scope)
        #expect(model.chartFlow(for: .worldwide)?.playlistId == world.playlistId && model.chartFlow(for: .genre(132))?.count == 3)
        // Signing out forgets them.
        model.signOut()
        #expect(model.aurralFeeds.chartFlows.flows.isEmpty)
        model.aurralFeeds.follow(scope: scope)
        #expect(model.aurralFeeds.chartFlows.flows.isEmpty, "the saved copy went with the sign-out")
    }

    @Test func aNameTakenGetsANumber() async throws {
        let model = try await model()
        defer { model.signOut() }
        aurral.addSharedPlaylist(id: "own-1", name: "Top Worldwide", provider: nil, songs: [])
        let flow = try await model.createChartFlow(try await model.chartPage(.worldwide), count: 4)
        #expect(flow.name == "Top Worldwide 2")
    }

    @Test func aFlowRemovedOnTheServerCanBeCreatedAgain() async throws {
        let model = try await model()
        defer { model.signOut() }
        let page = try await model.chartPage(.worldwide)
        let flow = try await model.createChartFlow(page, count: 3)
        let other = AurralClient(base: aurral.base, session: aurral.signedInSession(), transport: aurral)
        try await other.deleteChartFlow(playlistId: flow.playlistId)
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

    /// The words (owner: "Create flow…", "Edit flow", "Refresh now", "Songs: N"); never the server's name.
    @Test func theWords() {
        #expect(DiscoverPagesCopy.createFlow == "Create flow\u{2026}" && DiscoverPagesCopy.editFlow == "Edit flow")
        #expect(DiscoverPagesCopy.refreshNow == "Refresh now" && DiscoverPagesCopy.flowSongs(10) == "Songs: 10")
        let words = [DiscoverPagesCopy.createFlow, DiscoverPagesCopy.createFlowTitle, DiscoverPagesCopy.editFlow,
                     DiscoverPagesCopy.refreshNow, DiscoverPagesCopy.removeFlow, DiscoverPagesCopy.removeFlowQuestion,
                     DiscoverPagesCopy.removeFlowNote, DiscoverPagesCopy.flowNote("Worldwide", 10), DiscoverPagesCopy.makeDefault,
                     DiscoverPagesCopy.defaultChart, DiscoverPagesCopy.charts, DiscoverPagesCopy.countries, DiscoverPagesCopy.genres,
                     DiscoverPagesCopy.chooseChart("Worldwide"), DiscoverPagesCopy.topSongs(chart: "Pop"),
                     DiscoverCopy.message(for: AurralError.nameTaken)]
        for word in words {
            for name in ["Aurral", "Lidarr", "Navidrome", "Deezer"] { #expect(!word.localizedCaseInsensitiveContains(name), "\(word)") }
        }
    }
}
