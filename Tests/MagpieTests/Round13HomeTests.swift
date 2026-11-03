import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Testing
@testable import Magpie

/// The stub Aurral (which can be made slow) on its host; everything else to the Navidrome mock.
final class SlowAurralRouting: HTTPTransport, @unchecked Sendable {
    let aurral = StubAurral()
    let navidrome = MockTransport()
    private let delay = OSAllocatedUnfairLock<Duration?>(initialState: nil)
    /// Every Aurral request waits this long first (nil: answers at once).
    func setAurralDelay(_ value: Duration?) { delay.withLock { $0 = value } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == aurral.host {
            if let wait = delay.withLock({ $0 }) { try await Task.sleep(for: wait) }
            return try await aurral.send(request)
        }
        return try await navidrome.send(request)
    }
}

private func ok(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

/// Round 13 item 5: Home's Discover and Playlists sections, with Aurral fine, slow, down or signed out, and with
/// Home's saved shelves from build 12. Never the owner's servers.
@MainActor @Suite(.serialized) final class Round13HomeTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "Round13HomeTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "Round13HomeTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = SlowAurralRouting()
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()
    var aurral: StubAurral { transport.aurral }

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    static let flows: [StubAurral.Flow] = [.init(id: "flow-dw", name: "Discover Weekly"), .init(id: "flow-tm", name: "Trending Mix")]
    static let jobs: [StubAurral.Job] = [
        .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", trackMbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3",
              durationMs: 251_000, finalPath: "/data/downloads/aurral/_flows/flow-dw/Low/Single/Lullaby.flac"),
        .init(flowId: "flow-dw", artistName: "Low", trackName: "Words",
              finalPath: "/data/downloads/aurral/_flows/flow-dw/Low/Single/Words.flac"),
        .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000,
              finalPath: "/data/downloads/aurral/_flows/flow-dw/Nobody/Single/Unknown Song.mp3"),
        .init(flowId: "flow-dw", artistName: "Low", trackName: "Halo",
              finalPath: "/data/downloads/aurral/_flows/flow-dw/Low/Single/Halo.mp3"),
    ]

    /// Signed in, Aurral connected and read once (Discover is "Discover Weekly").
    func signedIn() async throws -> AppModel {
        nav.install(on: transport.navidrome)
        transport.navidrome.stub(pathSuffix: "/rest/getAlbumList2") { _ in
            let albums = (1...3).map { #"{"id":"al-r\#($0)","name":"Random \#($0)","artist":"R","songCount":1,"duration":60}"# }
            return .init(status: 200, body: ok(#""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#))
        }
        aurral.setFlows(Self.flows)
        aurral.setJobs(Self.jobs)
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        _ = try await model.connectAurral(base: aurral.base, apiKey: aurral.apiKey)
        #expect(model.discover.playlists.map(\.playlist.id) == ["pl-dw"])
        return model
    }

    /// As after a relaunch: nothing read this session, what was saved for the account stays.
    func relaunched(_ model: AppModel) { model.discover.forgetReads() }

    /// Aurral ran the flow since: Discover Weekly now holds songs Magpie has never seen (new ids), each one a job.
    func flowRotated() {
        nav.lists["pl-dw"] = ("Discover Weekly", ["a-new1", "a-new2", "a-new3"])
        nav.addSongs([
            .init(id: "a-new1", title: "New One", artist: "Fresh", duration: 200, mbid: nil, library: 2),
            .init(id: "a-new2", title: "New Two", artist: "Fresh", duration: 210, mbid: nil, library: 2),
            .init(id: "a-new3", title: "New Three", artist: "Fresh", duration: 220, mbid: nil, library: 2),
        ])
        aurral.setJobs(["New One", "New Two", "New Three"].enumerated().map { i, title in
            .init(flowId: "flow-dw", artistName: "Fresh", trackName: title, durationMs: (200 + 10 * i) * 1000,
                  finalPath: "/data/downloads/aurral/_flows/flow-dw/Fresh/Single/\(title).flac")
        })
    }

    private func ids(_ shelves: [HomeShelf], _ section: HomeSection) -> [String]? {
        shelves.first { $0.section == section }?.items.map(\.id)
    }

    /// What every Home read must show: Discover is Aurral's playlist and nothing else; Playlists the owner's own,
    /// never Aurral's; no album in either.
    private func expectRightShelves(_ shelves: [HomeShelf], _ label: Comment) {
        #expect(ids(shelves, .discover) == ["playlist-pl-dw"], label)
        #expect(ids(shelves, .playlists) == ["playlist-pl-mine", "playlist-pl-road", "playlist-pl-empty"], label)
        #expect(ids(shelves, .randomAlbums) == ["album-al-r1", "album-al-r2", "album-al-r3"], label)
    }

    // MARK: - Symptom: Discover replaced, Playlists showing Aurral's playlists

    /// Two Home reads in a row (Aurral read again before each): the second one sees what the first one's Aurral read
    /// decided, so a playlist moved from Discover to Playlists shows there.
    private func expectRightShelvesTwice(_ model: AppModel, _ label: String) async throws {
        expectRightShelves(try await model.homeShelves(for: [.discover, .playlists, .randomAlbums]), "\(label), first read")
        model.discover.statusReadAt = nil
        expectRightShelves(try await model.homeShelves(for: [.discover, .playlists, .randomAlbums]), "\(label), second read")
    }


    @Test func aurralFine() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        relaunched(model)
        expectRightShelves(try await model.homeShelves(for: [.discover, .playlists, .randomAlbums]), "Aurral fine")
    }

    @Test func aurralDown() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        relaunched(model)
        aurral.setDown(true)
        expectRightShelves(try await model.homeShelves(for: [.discover, .playlists, .randomAlbums]), "Aurral down")
    }

    @Test func aurralSignedOut() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        relaunched(model)
        // Aurral now refuses the saved sign-in (401 on everything but health).
        model.discover.connection = AurralConnection(base: aurral.base, apiKey: "revoked")
        expectRightShelves(try await model.homeShelves(for: [.discover, .playlists, .randomAlbums]), "Aurral signed out")
    }

    /// The flow ran since the last launch, and Aurral's job list can't be read (slow, or the route is gone): the
    /// playlist Aurral publishes for the flow is still Discover's.
    @Test func flowRanAndJobsUnreadable() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        relaunched(model)
        flowRotated()
        aurral.setJobsRoute(false)
        try await expectRightShelvesTwice(model, "jobs unreadable")
    }

    /// The flow is running: Aurral cleared its jobs while Navidrome still holds the last run's playlist.
    @Test func flowRunningJobsCleared() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        flowRotated()
        aurral.setJobs([])
        model.discover.statusReadAt = nil   // read again now
        try await expectRightShelvesTwice(model, "jobs cleared")
    }

    // MARK: - Review I1: a status read that doesn't name the flow never removes a known Discover playlist

    /// Aurral answers but lists no flows (Z1's fail-closed status when the user isn't known): nothing changes.
    @Test func statusWithNoFlowsKeepsDiscover() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        relaunched(model)
        aurral.setFlows([])
        try await expectRightShelvesTwice(model, "no flows")
    }

    /// No flows AND the jobs cleared by a run AND new songs: still nothing changes.
    @Test func noFlowsDuringARunKeepsDiscover() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        relaunched(model)
        flowRotated()
        aurral.setJobs([])
        aurral.setFlows([])
        try await expectRightShelvesTwice(model, "no flows, run under way")
    }

    /// The flow was renamed in Aurral before its playlist was: the playlist (still the flow's songs) stays Discover's,
    /// under the renamed flow.
    @Test func flowRenamedBeforeItsPlaylist() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        relaunched(model)
        aurral.setFlows([.init(id: "flow-dw", name: "Weekly Picks"), .init(id: "flow-tm", name: "Trending Mix")])
        try await expectRightShelvesTwice(model, "flow renamed")
        #expect(model.discoverFlow(playlistId: "pl-dw")?.id == "flow-dw")
    }

    /// Positive evidence only: Aurral lists its flows, none is named as the playlist, and its songs are no longer
    /// the flow's (the owner reused it for library songs): it leaves Discover and is an ordinary playlist again.
    @Test func playlistLeavesDiscoverOnlyOnPositiveEvidence() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        relaunched(model)
        aurral.setFlows([.init(id: "flow-dw", name: "Weekly Picks"), .init(id: "flow-tm", name: "Trending Mix")])
        nav.lists["pl-dw"] = ("Discover Weekly", ["m-x", "m-y"])
        defaults.removeObject(forKey: AppModel.aurralSongsKey(try #require(model.navidromeScope)))
        _ = try await model.homeShelves(for: [.discover, .playlists])
        model.discover.statusReadAt = nil
        let shelves = try await model.homeShelves(for: [.discover, .playlists])
        #expect(ids(shelves, .discover) == nil)
        #expect(ids(shelves, .playlists)?.contains("playlist-pl-dw") == true)
    }

    /// Review M7: Home updates by itself once a slow Aurral answers (nothing known before: a first launch).
    @Test func homeUpdatesWhenSlowAurralAnswers() async throws {
        let model = try await signedIn()
        defer { transport.setAurralDelay(nil); model.signOut() }
        let scope = try #require(model.navidromeScope)
        relaunched(model)
        defaults.removeObject(forKey: AppModel.discoverPlaylistsKey(scope))
        model.homeFeedSlot = nil
        HomeShelfCache.removeAll(root: tmp)
        transport.setAurralDelay(.seconds(2))   // status + jobs: 4 s, past the 3 s wait
        let feed = model.homeFeed
        let key = HomeLoad.Key.make(sections: [.discover, .playlists, .randomAlbums], offline: false, onPhone: nil,
                                    genres: model.preferences.genres)
        await feed.show(key)
        #expect(feed.load?.found[.discover] == nil, "not known yet: no Discover after the wait")
        for _ in 0..<150 where feed.load?.found[.discover] == nil || feed.isReading {
            try await Task.sleep(for: .milliseconds(100))
        }
        let found = try #require(feed.load?.found)
        expectRightShelves([.discover, .playlists, .randomAlbums].compactMap { found[$0] }, "after Aurral answered")
    }

    /// Aurral slow: Home doesn't wait for it, and Discover shows the playlists known to be Discover's.
    @Test func aurralSlow() async throws {
        let model = try await signedIn()
        defer { transport.setAurralDelay(nil); model.signOut() }
        relaunched(model)
        transport.setAurralDelay(.seconds(30))
        let clock = ContinuousClock()
        let start = clock.now
        let shelves = try await model.homeShelves(for: [.discover, .playlists, .randomAlbums])
        #expect(clock.now - start < .seconds(10), "Home waited \(clock.now - start) for Aurral")
        expectRightShelves(shelves, "Aurral slow")
        transport.setAurralDelay(nil)
    }

    /// Discover's playlists changed while Home was reading (the read of Aurral finished after the wait): Home reads
    /// Discover and Playlists once more, and only those.
    @Test func homeReadsDiscoverAndPlaylistsAgainWhenDiscoverChanges() async throws {
        let dw = Playlist(id: "pl-dw", name: "Discover Weekly", songCount: 4, duration: 0)
        let road = Playlist(id: "pl-road", name: "Road trip", songCount: 4, duration: 0)
        let album = Album(id: "al-r1", name: "Random 1", artist: "R", songCount: 1, duration: 60)
        var calls: [[HomeSection]] = []
        var feed: HomeFeed?
        feed = HomeFeed(cache: nil, read: { sections in
            calls.append(sections)
            if calls.count == 1 {
                feed?.sectionsChanged([.discover, .playlists])   // Aurral's read ends during Home's
                return AppModel.HomeRead(shelves: [HomeShelf(section: .playlists, items: [.playlist(dw), .playlist(road)]),
                                                   HomeShelf(section: .randomAlbums, items: [.album(album)])], failed: [])
            }
            return AppModel.HomeRead(shelves: [HomeShelf(section: .discover, items: [.playlist(dw)]),
                                               HomeShelf(section: .playlists, items: [.playlist(road)])], failed: [])
        }, sleep: { _ in try await Task.sleep(for: .seconds(600)) })
        let home = try #require(feed)
        let key = HomeLoad.Key.make(sections: [.discover, .playlists, .randomAlbums], offline: false, onPhone: nil,
                                    genres: .defaultValue)
        await home.show(key)
        for _ in 0..<200 where home.isReading || calls.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls == [[.discover, .playlists, .randomAlbums], [.discover, .playlists]])
        #expect(home.load?.found[.discover]?.items.map(\.id) == ["playlist-pl-dw"])
        #expect(home.load?.found[.playlists]?.items.map(\.id) == ["playlist-pl-road"])
        #expect(home.load?.found[.randomAlbums]?.items.map(\.id) == ["album-al-r1"], "kept, not read again")
        home.stop()
    }

    /// The rule on its own: confirmed now, or Discover's before and still named after its flow with no other
    /// playlist confirmed for it.
    @Test func keptFlowPlaylistsRule() {
        let dw = AurralFlow(id: "flow-dw", name: "Discover Weekly")
        func candidate(_ id: String) -> DiscoverPlaylist {
            DiscoverPlaylist(flow: dw, playlist: Playlist(id: id, name: "Discover Weekly", songCount: 1, duration: 0))
        }
        let old = candidate("pl-old"), new = candidate("pl-new"), mine = candidate("pl-mine")
        #expect(AppModel.keptFlowPlaylists([old, mine], confirmed: [], before: ["pl-old"]) == [old], "unconfirmed: kept")
        #expect(AppModel.keptFlowPlaylists([old, mine], confirmed: [], before: []) == [], "never confirmed: never Discover")
        #expect(AppModel.keptFlowPlaylists([old, new], confirmed: [new], before: ["pl-old"]) == [new], "another confirmed")
        #expect(AppModel.keptFlowPlaylists([mine], confirmed: [], before: ["pl-old"]) == [], "renamed away: gone")
    }

    // MARK: - Home's saved shelves from build 12

    /// Build 12 saved Discover's shelf (playlists) with the others; at launch it shows at once, in its place.
    @Test func build12CacheShowsDiscover() throws {
        let cache = HomeShelfCache(root: tmp, scope: "b12")
        let dw = Playlist(id: "pl-dw", name: "Discover Weekly", songCount: 4, duration: 0)
        let road = Playlist(id: "pl-road", name: "Road trip", songCount: 4, duration: 0)
        let album = Album(id: "al-r1", name: "Random 1", artist: "R", songCount: 1, duration: 60)
        cache.save([HomeShelf(section: .discover, items: [.playlist(dw)]),
                    HomeShelf(section: .playlists, items: [.playlist(road)]),
                    HomeShelf(section: .randomAlbums, items: [.album(album)])])
        let loaded = cache.load()
        #expect(loaded.map(\.section) == [.discover, .playlists, .randomAlbums])
        // A shelf of the wrong kind is still thrown away: albums under Discover or Playlists.
        cache.save([HomeShelf(section: .discover, items: [.album(album)]), HomeShelf(section: .playlists, items: [.album(album)])])
        #expect(cache.load().isEmpty)
    }

    /// The feed, end to end: from build 12's saved shelves, with Aurral slow, Home shows the right shelves at every
    /// step and never an album under Discover or Playlists.
    @Test func feedFromBuild12CacheWithAurralSlow() async throws {
        let model = try await signedIn()
        defer { transport.setAurralDelay(nil); model.signOut() }
        let scope = try #require(model.navidromeScope)
        relaunched(model)
        let dw = Playlist(id: "pl-dw", name: "Discover Weekly", songCount: 4, duration: 0)
        let mine = Playlist(id: "pl-mine", name: "Discover Weekly", songCount: 2, duration: 0)
        let album = Album(id: "al-r1", name: "Random 1", artist: "R", songCount: 1, duration: 60)
        HomeShelfCache(root: tmp, scope: scope).save([HomeShelf(section: .discover, items: [.playlist(dw)]),
                                                     HomeShelf(section: .playlists, items: [.playlist(mine)]),
                                                     HomeShelf(section: .randomAlbums, items: [.album(album)])])
        model.homeFeedSlot = nil   // a new launch's feed, from the saved shelves
        transport.setAurralDelay(.seconds(30))
        let feed = model.homeFeed
        #expect(feed.load?.found[.discover] != nil, "Discover shows from the saved shelves at once")
        let key = HomeLoad.Key.make(sections: [.discover, .playlists, .randomAlbums], offline: false, onPhone: nil,
                                    genres: model.preferences.genres)
        await feed.show(key)
        let found = try #require(feed.load?.found)
        expectRightShelves([.discover, .playlists, .randomAlbums].compactMap { found[$0] }, "after the read")
        transport.setAurralDelay(nil)
    }
}

extension DiscoverNavidrome {
    func addSongs(_ entries: [Entry]) { for entry in entries { songs[entry.id] = entry } }
}

/// Round 13 item 2: a pull's load cut short is never an error, and the pull's work outlives SwiftUI letting go of it.
@MainActor struct Round13RefreshTests {
    private func isFailed<T>(_ state: Loadable<T>) -> Bool { if case .failed = state { true } else { false } }

    @Test func aLoadCutShortIsNeverAnError() {
        let loading: Loadable<Int> = .loading, shown: Loadable<Int> = .loaded(7)
        #expect(!isFailed(loading.failing(CancellationError())))
        #expect(!isFailed(loading.failing(URLError(.cancelled))))
        #expect(shown.failing(URLError(.cancelled)).value == 7)
        #expect(shown.failing(URLError(.timedOut)).value == 7, "what is shown stays when a reload fails")
        #expect(isFailed(loading.failing(URLError(.timedOut))), "nothing to show: the error")
    }

    @Test func pullWorkOutlivesTheCancelledPull() async {
        var finished = false
        let pull = Task { @MainActor in
            await RefreshSafety.run {
                try? await Task.sleep(for: .milliseconds(200))
                finished = !Task.isCancelled
            }
        }
        pull.cancel()   // SwiftUI letting go of the refresh
        await pull.value
        #expect(finished)
    }
}
