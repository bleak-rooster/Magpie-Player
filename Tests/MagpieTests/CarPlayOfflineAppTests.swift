import CarPlay
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Testing
import UIKit
@testable import CarPlayUI
@testable import Magpie

/// Round 28 O4: the routes the car tests talk to (the stub Navidrome and Aurral of `FailableD1Routing`), which can be
/// made unreachable (a tunnel), and which keep every URL that reached them (after the offline gate).
final class CarOfflineRoutes: HTTPTransport, @unchecked Sendable {
    let inner = FailableD1Routing()
    private let state = OSAllocatedUnfairLock(initialState: (down: false, sent: [URL]()))
    var down: Bool {
        get { state.withLock { $0.down } }
        set { state.withLock { $0.down = newValue } }
    }
    var sent: [URL] { state.withLock { $0.sent } }
    func forget() { state.withLock { $0.sent = [] } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let down = state.withLock { s -> Bool in
            if let url = request.url { s.sent.append(url) }
            return s.down
        }
        if down { throw URLError(.notConnectedToInternet) }
        return try await inner.send(request)
    }
}

/// Round 28 O4 (owner, 2026-11-15): the car offline (D347, D348) and in a tunnel (design critique L4). Going offline
/// takes each tab back to its first list (Now Playing stays); coming back online leaves the car where it is; the car's
/// lists and Home are the phone's offline ones, from O2's pages; a partial page says "<n> of <m> on this iPhone".
@MainActor @Suite(.serialized) final class CarPlayOfflineAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "CarPlayOfflineAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "CarPlayOfflineAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let routes = CarOfflineRoutes()
    let engine = FakeEngine()
    let aurralStore = MemoryAurralStore()
    let lidarrStore = MemoryLidarrStore()
    let tokenStore = MemoryTokenStore()
    var aurral: StubAurral { routes.inner.inner.aurral }
    var nav: D1Navidrome { routes.inner.inner.navidrome }

    deinit {
        routes.inner.inner.releaseStatus()
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    static let server = URL(string: "http://192.168.1.2:4533")!

    /// Signed in on the stub library: Discover Weekly ("pl-dw": Lullaby's library copy "m-lullaby", "a-unknown",
    /// "m-ref1") with Aurral (`aurralSetUp`), a playlist "pl-road" (Road: "m-ref1", "m-ref2", "m-lullaby"), and Lidarr
    /// and a ListenBrainz token when asked.
    func signedIn(aurralSetUp: Bool = false, lidarr: Bool = false, listenBrainz: Bool = false) async throws -> AppModel {
        nav.add(.init(id: "a-lullaby", title: "Lullaby", artist: "Low", duration: 251, mbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3", library: 2))
        nav.add(.init(id: "m-lullaby", title: "Lullaby", artist: "Low", duration: 252, mbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3", library: 1))
        nav.add(.init(id: "a-unknown", title: "Unknown Song", artist: "Nobody", duration: 180, mbid: nil, library: 2))
        nav.add(.init(id: "m-ref1", title: "Ref One", artist: "Q", duration: 100, mbid: nil, library: 1))
        nav.add(.init(id: "m-ref2", title: "Ref Two", artist: "Q", duration: 100, mbid: nil, library: 1))
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "a-unknown", "m-ref1"])
        nav.setList("pl-road", "Road", ["m-ref1", "m-ref2", "m-lullaby"])
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly")])
        aurral.setJobs([
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", trackMbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3",
                  durationMs: 251_000),
            .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000),
        ])
        if lidarr { try lidarrStore.save(LidarrConnection(base: URL(string: "http://127.0.0.1:8686")!, apiKey: "test-key")) }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: tokenStore, aurralStore: aurralStore,
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: routes, probeTransport: routes,
                             engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        try await model.signIn(urls: [Self.server], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if aurralSetUp {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        if listenBrainz { try model.setListenBrainzToken("test-key") }
        await model.scopeIndexRefresh?.value
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        return model
    }

    static func song(_ id: String, title: String? = nil, artist: String = "Q", artistId: String? = "ar-q",
                     album: String = "A", albumId: String? = nil) -> Song {
        Song(id: id, title: title ?? id, artist: artist, artistId: artistId, album: album, albumId: albumId ?? "al-\(id)",
             duration: 100)
    }

    func download(_ model: AppModel, _ songs: [Song]) async {
        model.download(songs, reason: .song)
        await model.downloads!.settled()
    }

    /// The car on the fake screen, showing its tabs.
    func car(_ model: AppModel) async -> (FakeCarInterface, CarPlayController) {
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        controller.setAvailability(.ready(account: "one"))
        _ = await eventually { car.tabs != nil }
        return (car, controller)
    }

    func goOffline(_ model: AppModel) async {
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await eventually { model.isOffline })
    }

    /// Leaving Offline mode: online once the login answers (O1 fix round 1, design H1).
    func goOnline(_ model: AppModel) async {
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually(10) { !model.isOffline })
    }

    var nowPlaying: CPNowPlayingTemplate { CPNowPlayingTemplate.shared }

    // MARK: - D347: the pop

    @Test func car_goingOfflinePopsToTheFirstList() async throws {
        let model = try await signedIn()
        let (car, controller) = await car(model)
        defer { controller.disconnect() }
        controller.open(.album(id: "al-server", title: "On the server"))
        controller.open(.artist(id: "ar-server", name: "Someone"))
        #expect(car.templates.count == 3)
        let tabs = car.tabs
        await goOffline(model)
        #expect(await eventually { car.templates.count == 1 }, "back to the tabs")
        #expect(car.tabs != nil && car.tabs !== tabs, "the tabs are built again from what's on the phone")
        #expect(FakeCarInterface.texts(car.tab(1)) == CarPlayRows.libraryRoot(CarPlayLibraryAdapter(model: model).libraryRows)
            .flatMap(\.rows).map(\.title), "the Library tab's first list is the offline one")
        #expect(controller.bindings.count == [controller.home, controller.libraryRoot, controller.thirdRoot].compactMap { $0 }.count + 1,
                "nothing left of the popped lists (the tab roots and Search only)")
    }

    @Test func car_goingOfflineKeepsNowPlaying() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("m-ref1")])
        let (car, controller) = await car(model)
        defer { controller.disconnect() }
        controller.open(.album(id: "al-server", title: "On the server"))
        model.play([Self.song("m-ref1"), Self.song("m-ref2")], startAt: 0)
        controller.showNowPlaying()
        #expect(car.templates.last === nowPlaying && car.templates.count == 3)
        await goOffline(model)
        #expect(await eventually { car.templates.count == 2 })
        #expect(car.templates.first is CPTabBarTemplate && car.templates.last === nowPlaying, "Now Playing stays on top")
    }

    @Test func car_comingOnlineKeepsItsPlace() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("m-ref1")])
        let (car, controller) = await car(model)
        defer { controller.disconnect() }
        let onlineTabs = car.tabs
        await goOffline(model)
        #expect(await eventually { car.tabs !== onlineTabs && car.templates.count == 1 })
        let offlineLibrary = FakeCarInterface.texts(car.tab(1))
        car.tap("Downloads", in: car.tab(1))
        #expect(await eventually { FakeCarInterface.texts(car.topList).contains("A") }, "the album on the phone")
        let downloads = car.topList
        let rows = FakeCarInterface.texts(downloads)
        await goOnline(model)
        // The Library tab (off screen) follows the online rows: the watch has seen the change.
        #expect(await eventually { FakeCarInterface.texts(car.tab(1)) != offlineLibrary })
        #expect(car.templates.count == 2 && car.topList === downloads, "the list stays where it was")
        #expect(FakeCarInterface.texts(car.topList) == rows, "and keeps its shape")
    }

    // MARK: - D347: the lists

    @Test func car_offlineLibraryRowsFollowThePhone() async throws {
        for aurralSetUp in [false, true] {
            let model = try await signedIn(aurralSetUp: aurralSetUp, lidarr: true)
            let adapter = CarPlayLibraryAdapter(model: model)
            await goOffline(model)
            let phone = model.libraryRows(carPlay: false)
            #expect(adapter.libraryRows == phone.filter { $0 != .requests }, "the phone's offline rows without Requests")
            #expect(!adapter.libraryRows.contains(.requests))
            model.updatePreferences { $0.carPlay.flowsWithPlaylists = true }
            #expect(!adapter.libraryRows.contains(.discover), "D300: Discover's flows are in Playlists")
            model.updatePreferences { $0.carPlay.flowsWithPlaylists = false }
            model.signOut()
        }
    }

    @Test func car_offlineAlbumPartialDetail() async throws {
        let model = try await signedIn()
        let one = Self.song("m-ref1", artist: "Low", artistId: "ar-low", album: "Things", albumId: "al-things")
        await download(model, [one])
        let album = Album(id: "al-things", name: "Things", artist: "Low", artistId: "ar-low", songCount: 3, duration: 300)
        let songs = [one, Self.song("m-ref2", albumId: "al-things"), Self.song("m-x", albumId: "al-things")]
        await model.recordAlbumPage(album, songs: songs, into: model.downloads)
        await goOffline(model)
        let adapter = CarPlayLibraryAdapter(model: model)
        let read = try await adapter.album(id: "al-things")
        #expect(read.songCount == 3 && read.songs?.map(\.id) == ["m-ref1"])
        let (car, controller) = await car(model)
        defer { controller.disconnect() }
        controller.open(.album(id: "al-things", title: "Things"))
        #expect(await eventually { car.topList?.sections.first?.items.first.map { ($0 as? CPListItem)?.detailText } == "1 of 3 on this iPhone" })
        // Downloads opens it the same way.
        car.pop(to: car.tabs!, animated: false, completion: nil)
        controller.open(.downloadedAlbum(id: "al-things", title: "Things"))
        #expect(await eventually { car.topList?.sections.first?.items.first.map { ($0 as? CPListItem)?.detailText } == "1 of 3 on this iPhone" })
    }

    @Test func car_offlineArtistIncludesAlbumArtists() async throws {
        let model = try await signedIn()
        let track = Self.song("m-ref1", artist: "Q", artistId: "ar-q", album: "Sampler", albumId: "al-comp")
        await download(model, [track])
        let album = Album(id: "al-comp", name: "Sampler", artist: "Various Artists", artistId: "ar-va", songCount: 12, duration: 1)
        await model.recordAlbumPage(album, songs: [track], into: model.downloads)
        await goOffline(model)
        let adapter = CarPlayLibraryAdapter(model: model)
        let artists = try await adapter.artists().map(\.id)
        #expect(artists.contains("ar-va") && artists.contains("ar-q"), "album artists and track artists")
        let (va, vaAlbums) = try await adapter.artist(id: "ar-va")
        #expect(va.name == "Various Artists" && vaAlbums.map(\.id) == ["al-comp"])
        let (_, qAlbums) = try await adapter.artist(id: "ar-q")
        #expect(qAlbums.map(\.id) == ["al-comp"], "a featured song's album still plays from the car")
    }

    @Test func car_offlineDiscoverListsFlowsOnThePhone() async throws {
        let model = try await signedIn(aurralSetUp: true)
        _ = try await model.discoverPlaylists()
        _ = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        await download(model, [Self.song("m-ref1")])
        await goOffline(model)
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(try await adapter.discoverPlaylists().map(\.id) == ["pl-dw"])
        let (flow, songs) = try await adapter.playlist(id: "pl-dw")
        #expect(songs.map(\.id) == ["m-ref1"] && flow.songCount == 3)
        #expect(try await adapter.playlists().map(\.id).contains("pl-dw") == false, "D185: flows stay out of Playlists")
        model.updatePreferences { $0.carPlay.flowsWithPlaylists = true }
        #expect(try await adapter.playlists().map(\.id).contains("pl-dw"), "D300: joined with Playlists")
        // Without a download in it, a flow isn't listed; without Aurral there are none.
        model.signOut()
        let bare = try await signedIn(aurralSetUp: false)
        await goOffline(bare)
        #expect(try await CarPlayLibraryAdapter(model: bare).discoverPlaylists().isEmpty)
    }

    @Test func car_offlinePlaylistsHoldingADownload() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("m-ref2")])
        let road = Playlist(id: "pl-road", name: "Road", songCount: 3, duration: 300)
        await model.recordPlaylistPage(road, songs: [Self.song("m-ref1"), Self.song("m-ref2"), Self.song("m-lullaby")],
                                       kind: .playlist, into: model.downloads)
        await goOffline(model)
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(try await adapter.playlists().map(\.id) == ["pl-road"], "Q3: read online, holding a download")
        let (list, songs) = try await adapter.playlist(id: "pl-road")
        #expect(songs.map(\.id) == ["m-ref2"] && list.songCount == 3)
    }

    @Test func car_offlineHomeShelves() async throws {
        let model = try await signedIn(aurralSetUp: true)
        _ = try await model.discoverPlaylists()
        _ = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        await download(model, [Self.song("m-ref1"), Self.song("m-ref2")])
        await model.recordPlaylistPage(Playlist(id: "pl-road", name: "Road", songCount: 3, duration: 300),
                                       songs: [Self.song("m-ref1"), Self.song("m-ref2"), Self.song("m-lullaby")],
                                       kind: .playlist, into: model.downloads)
        await goOffline(model)
        let adapter = CarPlayLibraryAdapter(model: model)
        let sections = adapter.homeSections
        #expect(Set(sections) == [.downloaded, .discover, .playlists])
        routes.forget()
        let shelves = try await adapter.homeShelves(sections, size: 4)
        #expect(shelves.map(\.section) == sections.filter { [.downloaded, .discover, .playlists].contains($0) })
        func ids(_ section: HomeSection) -> [String] {
            shelves.first { $0.section == section }?.items.map {
                switch $0 {
                case .album(let a): a.id
                case .playlist(let p): p.id
                default: "?"
                }
            } ?? []
        }
        #expect(Set(ids(.downloaded)) == ["al-m-ref1", "al-m-ref2"])
        #expect(ids(.discover) == ["pl-dw"] && ids(.playlists) == ["pl-road"])
        #expect(routes.sent.isEmpty, "nothing asked of the server offline")
    }

    @Test func car_offlineEmptyListSaysNothingDownloaded() async throws {
        let model = try await signedIn()
        let (car, controller) = await car(model)
        defer { controller.disconnect() }
        let onlineTabs = car.tabs
        await goOffline(model)
        #expect(await eventually { car.tabs !== onlineTabs && car.templates.count == 1 })
        car.tap("Downloads", in: car.tab(1))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Nothing downloaded yet"] })
        // Favourites keeps today's out-of-reach line (the phone doesn't know what's starred offline).
        car.pop(to: car.tabs!, animated: false, completion: nil)
        controller.open(.favourites)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["You're offline"] })
    }

    /// Pinned (R10, Task 23): offline, Now Playing's links go to the pages on the phone.
    @Test func car_nowPlayingLinksOffline() async throws {
        let model = try await signedIn()
        let one = Self.song("m-ref1", artist: "Low", artistId: "ar-low", album: "Things", albumId: "al-things")
        await download(model, [one])
        let (_, controller) = await car(model)
        defer { controller.disconnect() }
        await goOffline(model)
        model.play([one], startAt: 0)
        #expect(await eventually {
            controller.nowPlayingLinks.album == .downloadedAlbum(id: "al-things", title: "Things")
                && controller.nowPlayingLinks.artist == .downloadedArtist(id: "ar-low", name: "Low")
        })
    }

    // MARK: - The tunnel (design critique L4)

    /// CarPlay plays a stream; a 20-second tunnel takes the connection (offline at once, Q1). The queue stays whole, the
    /// stream that ran dry gives way to the next song on the phone, the car goes back to its first lists once and
    /// doesn't move again when the connection comes back; the songs passed over are still in the queue, and the next
    /// stream is sent again once the library answers.
    @Test func car_tunnelKeepsTheQueueAndTheCarsPlace() async throws {
        let model = try await signedIn()
        let clock = ManualReachabilityClock()
        model.useReachabilityClock(clock)
        await download(model, [Self.song("m-ref2")])
        let (car, controller) = await car(model)
        defer { controller.disconnect() }
        let queue = [Self.song("m-ref1"), Self.song("m-lullaby"), Self.song("m-ref2"), Self.song("a-unknown")]
        model.play(queue, startAt: 0)
        controller.showNowPlaying()
        #expect(engine.setItemsCalls.last?.items.first?.1.isFileURL == false, "a stream")

        // Into the tunnel: no path, and nothing answers.
        routes.down = true
        model.reachabilityEvent(.pathChanged(connected: false))
        #expect(await model.advanceReachability(clock, to: 3))
        #expect(model.isOffline && model.offlineState == .automatic)
        #expect(await eventually { car.templates.count == 2 && car.templates.last === self.nowPlaying },
                "back to the tabs, Now Playing on top")
        let stack = car.templates.map(ObjectIdentifier.init)
        // The buffer runs out: the next song on the phone plays; nothing is dropped from the queue.
        let current = try #require(model.player.queue.current)
        model.player.handle(.failed(current.id, "The network connection was lost.", undecodable: false))
        #expect(model.player.queue.current?.song.id == "m-ref2" && model.player.isPlaying)
        #expect(model.player.queue.main.map(\.song.id) == queue.map(\.id), "no queue is lost")

        // Out of the tunnel 20 s later.
        routes.down = false
        model.reachabilityEvent(.pathChanged(connected: true))
        #expect(await model.advanceReachability(clock, to: 23))
        #expect(await eventually(10) { !model.isOffline })
        #expect(car.templates.map(ObjectIdentifier.init) == stack, "the car doesn't move")
        #expect(model.player.queue.current?.song.id == "m-ref2", "the song on the phone plays on")
        #expect(await eventually { self.engine.setItemsCalls.last?.items.last?.1.isFileURL == false },
                "the next stream is sent again")
        let index = try #require(model.player.queue.currentIndex)
        #expect(model.player.queue.main[..<index].map(\.song.id) == ["m-ref1", "m-lullaby"],
                "the songs passed over are a Previous away")
    }

    // MARK: - Seeded: flips, pushes and Now Playing never leave the car past its limits

    /// 120 seeded sequences (hosted, so fewer than the package's 500) of opens, Now Playing, pops, plays and offline
    /// pops through the real controller. After every step: the stack within CarPlay's depth limit and browse depth
    /// within the budget; after going offline only the tabs (and Now Playing), and no binding left for a list that
    /// isn't on screen (the fake car never says a list went, so only the offline pop's clean-up is checked).
    @Test func offline_randomFlipsAndCarPushesKeepTheStack() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("m-ref1"), Self.song("m-ref2", albumId: "al-m-ref1")])
        let (car, controller) = await car(model)
        defer { controller.disconnect() }
        let destinations: [CPDestination] = [.albums, .artists, .playlists, .downloads, .genres, .songs,
                                             .album(id: "al-m-ref1", title: "A"), .downloadedAlbum(id: "al-m-ref1", title: "A"),
                                             .artist(id: "ar-q", name: "Q"), .favourites]
        for seed in 0..<UInt64(120) {
            var rng = SeededRNG(seed: seed &+ 0x0A4)
            for step in 0..<12 {
                let ctx = "seed \(seed) step \(step)"
                switch Int.random(in: 0...5, using: &rng) {
                case 0, 1: controller.open(destinations.randomElement(using: &rng)!)
                case 2: controller.showNowPlaying()
                case 3:
                    if let tabs = car.tabs { car.pop(to: tabs, animated: false, completion: nil) }
                case 4:
                    // Going offline, as the layout watch does it.
                    controller.goToFirstLists()
                    let rest = car.templates.dropFirst()
                    #expect(car.templates.first is CPTabBarTemplate && rest.count <= 1
                            && rest.allSatisfy { $0 === self.nowPlaying }, "\(ctx): \(car.templates)")
                default:
                    model.player.play([Self.song("m-ref1"), Self.song("m-ref2")], startAt: 0)
                }
                #expect(car.templates.count <= CPNavigator.carPlayTemplateDepthLimit, "\(ctx): \(car.templates.count) deep")
                #expect(controller.browseDepth <= CPNavigator.maxBrowseDepth, "\(ctx)")
            }
            if let tabs = car.tabs { car.pop(to: tabs, animated: false, completion: nil) }
            controller.goToFirstLists()
            #expect(controller.bindings.count == [controller.home, controller.libraryRoot, controller.thirdRoot]
                .compactMap { $0 }.count + 1, "seed \(seed): only the tabs' lists are bound after going offline")
        }
    }
}
