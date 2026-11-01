import CarPlayUI
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Search
import os
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let noNetwork = NetworkStatus(isConnected: false, isCellular: false, isConstrained: false)

/// Task 14: offline mode (Automatic / On / Off), browsing what's on the phone, and playing it with no server.
@MainActor @Suite(.serialized) final class OfflineAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "OfflineAppTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    let engine = FakeEngine()
    /// What `/auth/login` answers (tests make it fail while `/rest/ping` still answers).
    let loginStatus = OSAllocatedUnfairLock(initialState: 200)

    init() {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        let status = loginStatus
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login") { _ in
            let code = status.withLock { $0 }
            return MockTransport.Response(status: code, body: code == 200 ? loginJSON : Data())
        }
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2", body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}"#.utf8))
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeModel(fetcher: any AudioFetching, network: FakeNetwork = FakeNetwork(.wifi),
                   lidarrStore: MemoryLidarrStore = MemoryLidarrStore(),
                   tokenStore: MemoryTokenStore = MemoryTokenStore()) -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: tokenStore,
                 matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                 engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                 network: network, audioFetcher: fetcher)
    }

    /// Signed in, with pre-download off so only the songs a test downloads are on the phone.
    func signedInModel(fetcher: any AudioFetching) async throws -> AppModel {
        let model = makeModel(fetcher: fetcher)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        return model
    }

    func song(_ id: String) -> Song { PlayerTests.song(id) }

    /// A Lidarr connection on the dev-stack address (never contacted: the mock transport answers).
    func connectedLidarr() throws -> MemoryLidarrStore {
        let lidarr = MemoryLidarrStore()
        try lidarr.save(LidarrConnection(base: URL(string: "http://127.0.0.1:8686")!, apiKey: "key"))
        return lidarr
    }

    /// Every request the transport is asked to send from now on.
    func recordRequests() -> Recorder {
        let recorder = Recorder()
        transport.setHook { recorder.add($0) }
        return recorder
    }

    // MARK: - The brief's tests

    @Test func automaticOfflineWhenUnreachable() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(!model.isOffline)
        transport.setDown(["192.168.1.2"])
        await #expect(throws: URLError.self) { _ = try await model.request { try await $0.albumList(.newest, size: 1, offset: 0) } }
        #expect(!model.isOffline && model.reachability.isSuspect, "ruling (a): one failure is only suspect")
        await model.checkReachability()   // a second failed reconnect
        #expect(model.isOffline && !model.serverReachable)
        transport.setDown([])
        await model.checkReachability()
        #expect(!model.isOffline)
    }

    @Test func forcedOnAndOff() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.isOffline && model.serverReachable)
        model.updatePreferences { $0.downloads.offlineMode = .off }
        model.noteUnreachable()
        #expect(!model.isOffline)
    }

    @Test func offlineSkipsToNextLocalSong() async throws {               // Review Focus 5
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1"), song("s3")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await eventually { self.engine.setItemsCalls.last!.items.count == 2 })
        #expect(engine.setItemsCalls.last!.items.allSatisfy { $0.1.isFileURL })
        #expect(model.player.queue.upcoming.map(\.song.id) == ["s2", "s3"], "queue untouched")
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually { self.engine.setItemsCalls.last!.items.count == 3 })
    }

    /// Automatic offline (the server went away): the stream that fails gives way to the next song on the phone.
    /// (Fix round 2: Offline mode On doesn't wait for the failure; see `forcedOnStopsTheStreamingSong`.)
    @Test func offlineCurrentStreamFailureSkipsToNextLocal() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s3")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)      // s1 streams
        transport.setDown(["192.168.1.2"])
        await model.checkReachability(); await model.checkReachability()   // two failed reconnects: offline
        #expect(model.isOffline && model.player.queue.current?.song.id == "s1")
        model.player.handle(.failed(model.player.queue.current!.id, "offline"))
        #expect(model.player.queue.current?.song.id == "s3" && model.player.isPlaying && model.player.lastError == nil)
    }

    /// Offline mode On: a song still streaming stops at once, for the next song on the phone, or pauses.
    @Test func forcedOnStopsTheStreamingSong() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s3")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)      // s1 streams
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.player.queue.current?.song.id == "s3" && model.player.isPlaying)
        #expect(engine.setItemsCalls.last!.items.allSatisfy { $0.1.isFileURL })
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        model.play([song("s1")], startAt: 0)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(!model.player.isPlaying && model.player.lastError == "You're offline")
    }

    @Test func lidarrActionsDisabledOffline() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.tryAvailability.message == "You're offline")
    }

    @Test func offlineHomeAndLibraryFlags() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .album("a1")); await model.downloads!.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await model.offlineCatalog.albums().count == 1)
        #expect(model.localCoverURL(nil) == nil)
    }

    // MARK: - Controller additions and the owner's build

    /// Offline, a downloaded file that fails to decode is kept, nothing streams, and the next song on the phone plays.
    @Test func offlineDamagedLocalFileSkipsToNextLocal() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1"), song("s3")], reason: .song); await model.downloads!.settled()
        let file = try #require(model.downloads!.localFiles["s1"])
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let calls = engine.setItemsCalls.count
        model.player.handle(.failed(model.player.queue.current!.id, "cannot decode", undecodable: true))
        #expect(model.player.queue.current?.song.id == "s3" && model.player.isPlaying && model.player.lastError == nil)
        #expect(engine.setItemsCalls[calls...].allSatisfy { $0.items.allSatisfy { $0.1.isFileURL } }, "no stream tried")
        await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s1")?.kind == .download)
        #expect(FileManager.default.fileExists(atPath: file.path) && model.localFiles.url(for: "s1") == file)
    }

    /// Offline, no fallback to the original is tried: there's no server to ask, so the song fails like any that
    /// can't play.
    @Test func offlineHasNoOriginalFallback() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.playback.wifi = .opusMedium }
        model.play([song("s1")], startAt: 0)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.player.handle(.failed(model.player.queue.current!.id, "couldn't convert"))
        #expect(model.player.lastFallbackSongId == nil && model.player.lastError == "couldn't convert")
    }

    /// Waiting downloads aren't failed by going offline; they wait, and go once the server is back.
    @Test func downloadsWaitWhileOfflineAndResume() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        #expect(f.urls.isEmpty && model.downloadStatus(["s1"]) == .waitingForConnection)
        #expect(model.downloadStatus(["s1"]).text == "Waiting for a connection" && model.downloadStatus(["s1"]).symbol == "wifi.slash")
        #expect(model.downloads!.failed.isEmpty)
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually { model.downloads!.localFiles["s1"] != nil })
    }

    /// Requests aren't polled while offline (no runner tick), and polling starts again once online.
    @Test func noRequestPollingOffline() async throws {
        let model = makeModel(fetcher: FakeFetcher(), lidarrStore: try connectedLidarr())
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        let runner = try #require(model.runner)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.pollTask?.cancel(); model.pollTask = nil
        try await Task.sleep(for: .milliseconds(100))
        let ticks = await runner.tickCount
        model.pollRequests()
        model.isForeground = false; model.isForeground = true
        try await Task.sleep(for: .milliseconds(300))
        #expect(await runner.tickCount == ticks, "no tick while offline")
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually { await runner.tickCount > ticks })
    }

    /// Unreachable: probed again when the network comes back, and online again once the server answers.
    @Test func probesWhenTheNetworkReturns() async throws {
        let network = FakeNetwork(.wifi)
        let model = makeModel(fetcher: FakeFetcher(), network: network)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        network.status = noNetwork
        transport.setDown(["192.168.1.2"], with: .notConnectedToInternet)
        _ = try? await model.request { try await $0.albumList(.newest, size: 1, offset: 0) }
        await model.checkReachability()   // the second failed reconnect
        #expect(model.isOffline)
        transport.setDown([])
        network.status = .wifi
        #expect(await eventually { !model.isOffline })
    }

    /// Search offline: the downloads, then cached songs that played ("Recently played on this phone").
    @Test func offlineSearchSections() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let sections = await OfflineSearch(catalog: model.offlineCatalog).sections("ts1")
        #expect(sections.songs.map(\.id) == ["s1"] && sections.recentlyPlayed.isEmpty)
        #expect(sections.notYet.isEmpty)
    }

    /// The owner's build: a cold launch with no network and the server unreachable restores the session, goes
    /// offline, lists the downloads and plays them from the phone.
    @Test func coldLaunchWithNoNetworkPlaysDownloads() async throws {
        let online = try await signedInModel(fetcher: FakeFetcher())
        online.download([song("s1"), song("s2")], reason: .album("a1"), coverArtId: nil)
        await online.downloads!.settled()
        online.stopDownloads(erase: false)
        await online.downloadsTeardown?.value

        transport.setDown(["192.168.1.2"], with: .notConnectedToInternet)
        let f = FakeFetcher()
        let model = makeModel(fetcher: f, network: FakeNetwork(noNetwork))
        model.reachability.suspectInterval = .milliseconds(100)   // the second probe comes soon
        model.resumeSavedSession()
        #expect(model.session != nil)
        #expect(await eventually { model.isOffline }, "unreachable without any screen asking")
        await model.downloads!.settled()
        let albums = await model.offlineCatalog.albums()
        #expect(albums.count == 1 && albums[0].songs?.map(\.id) == ["s1", "s2"])
        model.play([song("s0")] + (albums[0].songs ?? []), startAt: 0)   // s0 isn't on the phone
        model.player.handle(.failed(model.player.queue.current!.id, "The Internet connection appears to be offline."))
        #expect(model.player.queue.current?.song.id == "s1" && model.player.isPlaying && model.player.lastError == nil)
        #expect(engine.setItemsCalls.last!.items.map(\.1.isFileURL) == [true, true])
        #expect(f.urls.isEmpty, "nothing fetched offline")
    }

    // MARK: - Fix round 1

    /// I1: Offline mode On sends nothing, with the server reachable: across launch, resume, play, scrobble, artwork,
    /// pull to refresh and coming to the foreground.
    @Test func forcedOnSendsNothing() async throws {
        let lidarr = try connectedLidarr()
        let tokens = MemoryTokenStore(); try tokens.save("lb-token")
        let onlineFetcher = FakeFetcher()
        let online = makeModel(fetcher: onlineFetcher, lidarrStore: lidarr, tokenStore: tokens)
        try await online.signIn(urls: [home], username: "admin", password: "pw")
        online.download([coverSong("s1")], reason: .album("al-1"), coverArtId: "al-1")
        await online.downloads!.settled()
        try await Task.sleep(for: .milliseconds(300))   // the signed-in model's own start-up work is done
        // A pre-download in flight when On is chosen is cancelled, and nothing more is fetched.
        online.updatePreferences { $0.downloads.preDownload = 1 }
        onlineFetcher.hold(after: onlineFetcher.urls.count)
        online.play([coverSong("s1"), song("s3")], startAt: 0)
        #expect(await eventually { onlineFetcher.inFlight == 1 })
        let fetched = onlineFetcher.urls.count
        let seen = recordRequests()
        online.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await eventually { onlineFetcher.inFlight == 0 }, "the pre-download in flight is cancelled")
        onlineFetcher.release()
        await online.downloads!.settled()
        #expect(onlineFetcher.urls.count == fetched && online.downloads!.localFiles["s3"] == nil)
        online.stopDownloads(erase: false)
        await online.downloadsTeardown?.value

        let f = FakeFetcher()
        let model = makeModel(fetcher: f, lidarrStore: lidarr, tokenStore: tokens)   // launch
        #expect(model.isOffline && model.serverReachable)
        model.resumeSavedSession()                                             // resume
        await model.downloads!.settled()
        model.play([coverSong("s1"), song("s2")], startAt: 0)                  // play
        model.player.listen(model.player.queue.current!.id, from: 0, to: 150, duration: 200)   // past the scrobble point
        await model.player.waitForPendingScrobbles()
        #expect(model.coverArtURL("al-1", size: 300) == nil)                   // artwork
        #expect(model.nowPlayingArtworkURL(coverSong("s1"))?.isFileURL ?? true)
        await model.checkReachability()                                        // pull to refresh, offline
        model.isForeground = false; model.isForeground = true                  // foreground
        _ = try? await model.request { try await $0.albumList(.newest, size: 1, offset: 0) }
        let found = try await model.carPlaySearch("t")                         // CarPlay search
        #expect(found.library.songs.map(\.id) == ["s1"] && found.notYet.isEmpty)
        _ = try? await model.mergedSearch().runReportingLibraryFailure("t")    // the phone's search, called directly
        #expect(await model.madeForYouTracks(MBID("2b9a3b3a-1f8e-4b55-9a0e-6f1f7c1c2d3e")!) == nil)   // Made for you tracks
        await #expect(throws: ListenBrainzTokenError.self) { try await model.saveListenBrainzToken("other") }
        #expect(await model.artistNotYetAlbums(Artist(id: "ar", name: "A", albumCount: 1), library: []).isEmpty)
        // Genres (T19): from the songs on the phone (s1 has no genre, so there are none), Play and Shuffle included.
        #expect(try await model.genreSections().isEmpty)
        #expect(try await model.allGenres().isEmpty)
        #expect(try await model.groupAlbums("rock").isEmpty)
        #expect(try await model.groupSongs("rock").isEmpty)
        #expect(try await model.genreAlbums("Rock").isEmpty)
        #expect(try await model.genreSongs("Rock").isEmpty)
        // Home (T20) with every section switched on: Downloaded only, and nothing asked even for every section.
        model.updatePreferences { for s in HomeSection.allCases { $0.layout.home.set(s, visible: true, keepingOneOf: []) } }
        #expect(model.homeSections == [.downloaded])
        #expect(try await model.homeShelves(for: model.homeSections).map(\.section) == [.downloaded])
        #expect(try await model.homeShelves(for: HomeSection.allCases).map(\.section) == [.downloaded])
        // Library (T21) with every row switched on: Genres (from the phone) and Downloads only, no Recently added
        // grid, and Songs and Favourites ask nothing.
        model.updatePreferences {
            for row in LibraryRow.allCases { $0.layout.library.set(row, visible: true, keepingOneOf: []) }
            $0.layout.showsRecentlyAdded = true
        }
        #expect(model.libraryRows == [.genres, .downloads] && !model.showsRecentlyAddedGrid)
        // The car (T22) mirrors it: Home is the Downloaded shelf, opened from the phone, and the Library the offline rows.
        let car = CarPlayLibraryAdapter(model: model)
        #expect(car.homeSections == [.downloaded] && car.libraryRows == [.genres, .downloads])
        #expect(car.isOffline)
        let carHome = CarPlayRows.home(try await car.homeShelves(car.homeSections, size: CarPlayRows.homeShelfMaxSize))
        #expect(carHome.map(\.header) == ["Downloaded"])
        let carRows = carHome.flatMap(\.rows)
        #expect(carRows.map(\.id) == ["home.downloaded.al-1"])
        #expect(carRows.first?.action == .open(.downloadedAlbum(id: "al-1", title: carRows.first?.title ?? "")))
        #expect(CarPlayRows.libraryRoot(car.libraryRows, hasFindsTab: true).flatMap(\.rows).map(\.title) == ["Genres", "Downloads"])
        // Every car destination (T23) reads the phone, or nothing: Genres, Downloads (albums, artists, playlists), an
        // album or playlist opened from search, Favourites, Made for you, genre Play and Shuffle, and the Finds shelf.
        #expect(try await car.genreGroups().isEmpty)
        #expect(try await car.genreSubgenres("rock").isEmpty)
        #expect(try await car.songs(for: .genreGroup(id: "rock", shuffled: true)).isEmpty)
        #expect(try await car.songs(for: .genre(name: "Rock", shuffled: false)).isEmpty)
        #expect(await car.downloadedAlbums().map(\.id) == ["al-1"])
        #expect(await car.downloadedPlaylists().isEmpty)
        let carArtists = await car.downloadedArtists()
        #expect(carArtists.map(\.name) == ["A"])
        #expect(await car.downloadedArtist(id: carArtists[0].id)?.1.map(\.id) == ["al-1"])
        #expect(await car.downloadedAlbum(id: "al-1")?.songs?.map(\.id) == ["s1"])
        #expect(try await car.album(id: "al-1").songs?.map(\.id) == ["s1"], "a search result's album opens from the phone")
        await #expect(throws: (any Error).self) { try await car.album(id: "elsewhere") }
        await #expect(throws: (any Error).self) { try await car.playlist(id: "p1") }
        #expect(try await car.albumList(.alphabeticalByName, size: 500).map(\.id) == ["al-1"])
        #expect(try await car.artists().map(\.name) == ["A"])
        #expect(try await car.playlists().isEmpty)
        await #expect(throws: (any Error).self) { try await car.favourites() }
        #expect(await car.madeForYouTracks(id: "2b9a3b3a-1f8e-4b55-9a0e-6f1f7c1c2d3e") == nil)
        #expect(try await car.homeShelves(HomeSection.allCases, size: CarPlayRows.homeShelfMaxSize).map(\.section) == [.downloaded])
        await car.refreshFinds()
        #expect(try await car.search("t").library.songs.map(\.id) == ["s1"])
        await #expect(throws: (any Error).self) { try await model.songsPage(0) }
        await #expect(throws: (any Error).self) { try await model.favourites() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(seen.urls.isEmpty, "sent: \(seen.urls.map(\.path))")
        #expect(f.urls.isEmpty)
        #expect(engine.setItemsCalls.last!.items.allSatisfy { $0.1.isFileURL })
        #expect(model.reachability.probes.isEmpty)
    }

    /// I2: the offline album shows its saved cover; songs carry their own (`mf-…`), the saved one is the album's.
    @Test func offlineAlbumFindsItsSavedCover() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([coverSong("s1"), coverSong("s2")], reason: .album("al-1"), coverArtId: "al-1")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let album = try #require(await model.offlineCatalog.albums().first)
        #expect(album.coverArtId == "al-1")
        let cover = try #require(model.localCoverURL(album.coverArtId))
        #expect(FileManager.default.fileExists(atPath: cover.path), "the saved cover is found")
        #expect(model.nowPlayingArtworkURL(album.songs![0]) == cover)
    }

    /// I3: the server drops mid-album with the network still up: nothing fails; once it answers, every song lands.
    @Test func serverDropMidAlbumWaitsThenLands() async throws {
        let fetcher = DropFetcher(allowed: 1)
        let model = try await signedInModel(fetcher: fetcher)
        model.updatePreferences { $0.downloads.concurrent = 1 }
        let songs = [song("s1"), song("s2"), song("s3")]
        transport.setDown(["192.168.1.2"])
        model.download(songs, reason: .album("a1")); await model.downloads!.settled()
        #expect(await eventually { model.reachability.failures >= 1 }, "the probe after the failure fails too: a drop")
        await model.downloads!.settled()
        #expect(model.downloads!.failed.isEmpty)
        #expect(model.downloads!.localFiles.count == 1)
        #expect(model.downloadStatus(songs.map(\.id), reason: .album("a1")) == .waitingForConnection)
        #expect(model.reachability.isSuspect)
        transport.setDown([]); fetcher.up()
        await model.checkReachability()
        #expect(await eventually { model.downloads!.localFiles.count == 3 })
        #expect(model.downloads!.failed.isEmpty && model.downloadStatus(songs.map(\.id), reason: .album("a1")) == .downloaded)
    }

    /// I4: back online, what offline held back runs again: the login, the match index, Made for you and Lidarr.
    @Test func backOnlineRestores() async throws {
        let tokens = MemoryTokenStore(); try tokens.save("lb-token")
        let model = makeModel(fetcher: FakeFetcher(), lidarrStore: try connectedLidarr(), tokenStore: tokens)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        model.updatePreferences { $0.downloads.offlineMode = .on }
        try await Task.sleep(for: .milliseconds(100))
        let seen = recordRequests()
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually { seen.urls.contains { $0.path.hasSuffix("/auth/login") } })
        #expect(await eventually { seen.urls.contains { $0.path.hasSuffix("/api/song") } }, "match index")
        #expect(await eventually { seen.urls.contains { $0.host == "127.0.0.1" } }, "Lidarr audit")
        #expect(await eventually { seen.urls.contains { $0.host == "api.listenbrainz.org" } }, "Made for you")
    }

    /// Ruling (a): a 3 s blip neither goes offline nor skips; the failed song plays again where it was.
    @Test func threeSecondBlipNeitherGoesOfflineNorSkips() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.play([song("s1"), song("s2")], startAt: 0)
        transport.setDown(["192.168.1.2"])
        model.player.handle(.failed(model.player.queue.current!.id, "The network connection was lost."))
        #expect(await eventually { model.reachability.isSuspect })
        try await Task.sleep(for: .seconds(3))
        #expect(!model.isOffline && model.player.queue.current?.song.id == "s1")
        #expect(engine.setItemsCalls.last!.items.count == 2, "nothing left out of the window")
        transport.setDown([])
        #expect(await eventually(10) { model.player.lastError == nil && model.player.isPlaying })
        #expect(!model.isOffline && !model.reachability.isSuspect && model.player.queue.current?.song.id == "s1")
    }

    /// Ruling (a): unreachable for `offlineAfter` goes offline even before a second failed reconnect.
    @Test func unreachableLongEnoughGoesOffline() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.reachability.offlineAfter = 0.1
        model.noteUnreachable()
        #expect(!model.isOffline)
        try await Task.sleep(for: .milliseconds(150))
        model.noteUnreachable()
        #expect(model.isOffline)
    }

    /// Offline, the cache keeps songs that played even with Keep recently played off.
    @Test func offlineCacheUpkeepRemovesNothing() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 2; $0.downloads.keepRecentlyPlayed = false }
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)
        #expect(await eventually { model.downloads!.localFiles["s2"] != nil && model.downloads!.localFiles["s3"] != nil })
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.player.next()                                                     // s2
        model.player.next()                                                     // s3: s2 has played
        #expect(await eventually { model.preDownloadSnapshot?.current?.song.id == "s3" })
        await model.cacheUpkeep?.value
        #expect(model.downloads!.localFiles["s2"] != nil, "nothing leaves the cache offline")
    }

    // MARK: - Fix round 2

    /// B: the server answers ping but every login fails: suspect ends offline within two probes, with the stream
    /// that failed moving on to the song on the phone instead of waiting for ever.
    @Test func loginFailuresEndOffline() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s2")], reason: .song); await model.downloads!.settled()
        model.reachability.suspectInterval = .milliseconds(50)
        model.reachability.interval = .milliseconds(50)
        model.play([song("s1"), song("s2")], startAt: 0)
        loginStatus.withLock { $0 = 500 }
        model.player.handle(.failed(model.player.queue.current!.id, "The network connection was lost."))
        model.noteUnreachable()
        #expect(await eventually(3) { model.isOffline })
        #expect(await eventually { model.player.queue.current?.song.id == "s2" && model.player.isPlaying })
    }

    /// B: a refused login (401) means the server answers: not offline, not suspect, and the sign-in error shows.
    @Test func refusedLoginIsNotOffline() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        loginStatus.withLock { $0 = 401 }
        model.noteUnreachable()
        await model.checkReachability()
        #expect(!model.isOffline && !model.reachability.isSuspect && model.reachability.authRejected)
        #expect(throws: NavidromeError.badCredentials) { try model.rethrowAuthRejection() }
        #expect(BrowseErrorCopy.message(for: NavidromeError.badCredentials) == ConnectErrorCopy.badCredentials)
        // Later a real outage: the sign-in error gives way to "isn't answering".
        transport.setDown(["192.168.1.2"])
        await model.checkReachability()
        #expect(!model.reachability.authRejected)
        #expect(throws: Never.self) { try model.rethrowAuthRejection() }
    }

    /// Fix round 3: downloads refused by a server that answers ping probe it sparingly (at most one probe per 5 s,
    /// logging in at most twice), and each song ends at "Couldn't download" after 3 attempts, with no tight loop.
    @Test func fastFailingDownloadsProbeSparingly() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.concurrent = 2 }
        let seen = recordRequests()
        f.failWith(URLError(.timedOut))
        let songs = [song("s1"), song("s2"), song("s3")]
        let start = Date()
        model.download(songs, reason: .album("a1"))
        try await Task.sleep(for: .seconds(4.5))
        // Counted by when each request was sent, not by when the test wakes (a late wake under load let a request
        // from the next 5 s window in: deflaked).
        let early = seen.sent(before: start.addingTimeInterval(4.5))
        #expect(early.filter { $0.path.hasSuffix("/auth/login") }.count <= 2, "few logins within 5 s")
        #expect(early.filter { $0.path.hasSuffix("/rest/ping") }.count <= 3, "few probes within 5 s")
        #expect(await eventually(15) { model.downloadStatus(songs.map(\.id), reason: .album("a1")) == .failed })
        #expect(model.downloadStatus(songs.map(\.id), reason: .album("a1")).text == "Couldn't download")
        let fetched = f.urls.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value }
        // 3 attempts a song; a fetch cancelled when the server turned suspect (not an attempt) may add one more.
        for id in songs.map(\.id) {
            #expect(fetched.filter { $0 == id }.count <= DownloadManager.maxConnectionAttempts + 1, "no loop: \(fetched)")
        }
        #expect(!model.isOffline)
    }

    func coverSong(_ id: String) -> Song {
        Song(id: id, title: "T\(id)", artist: "A", album: "B", albumId: "al-1", track: Int(id.dropFirst()),
             duration: 200, coverArtId: "mf-\(id)")
    }
}

/// Requests seen by the transport, from any thread.
final class Recorder: Sendable {
    private let seen = OSAllocatedUnfairLock<[(url: URL, at: Date)]>(initialState: [])
    var urls: [URL] { seen.withLock { $0.map(\.url) } }
    /// The requests sent before `date`.
    func sent(before date: Date) -> [URL] { seen.withLock { $0.filter { $0.at < date }.map(\.url) } }
    func add(_ request: URLRequest) { if let url = request.url { seen.withLock { $0.append((url, Date())) } } }
}

/// Fetches like `FakeFetcher` for the first `allowed` songs, then fails like a server that dropped, until `up()`.
final class DropFetcher: AudioFetching, Sendable {
    private let inner = FakeFetcher()
    private let state: OSAllocatedUnfairLock<(allowed: Int, down: Bool)>
    init(allowed: Int) { state = OSAllocatedUnfairLock(initialState: (allowed, true)) }
    func up() { state.withLock { $0.down = false } }

    func fetch(_ url: URL, allowsCellular: Bool) async throws -> (file: URL, mimeType: String?) {
        let fails = state.withLock { s -> Bool in
            if s.allowed > 0 { s.allowed -= 1; return false }
            return s.down
        }
        if fails { throw URLError(.cannotConnectToHost) }
        return try await inner.fetch(url, allowsCellular: allowsCellular)
    }
}
