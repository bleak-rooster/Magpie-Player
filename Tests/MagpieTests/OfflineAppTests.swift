import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Search
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

    init() {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2", body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}"#.utf8))
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeModel(fetcher: any AudioFetching, network: FakeNetwork = FakeNetwork(.wifi),
                   lidarrStore: MemoryLidarrStore = MemoryLidarrStore()) -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
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

    // MARK: - The brief's tests

    @Test func automaticOfflineWhenUnreachable() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(!model.isOffline)
        transport.setDown(["192.168.1.2"])
        await #expect(throws: URLError.self) { _ = try await model.request { try await $0.albumList(.newest, size: 1, offset: 0) } }
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

    @Test func offlineCurrentStreamFailureSkipsToNextLocal() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s3")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)      // s1 streams
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.player.handle(.failed(model.player.queue.current!.id, "offline"))
        #expect(model.player.queue.current?.song.id == "s3" && model.player.isPlaying && model.player.lastError == nil)
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
        model.updatePreferences { $0.playback.wifi = .opus128 }
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
        #expect(f.urls.isEmpty && model.downloadStatus(["s1"]) == .waitingForWiFi)
        #expect(model.downloads!.failed.isEmpty)
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually { model.downloads!.localFiles["s1"] != nil })
    }

    /// Requests aren't polled while offline, and polling starts again once online.
    @Test func noRequestPollingOffline() async throws {
        let lidarr = MemoryLidarrStore()
        try lidarr.save(LidarrConnection(base: URL(string: "http://127.0.0.1:8686")!, apiKey: "key"))
        let model = makeModel(fetcher: FakeFetcher(), lidarrStore: lidarr)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        #expect(model.runner != nil)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.pollTask?.cancel(); model.pollTask = nil
        model.pollRequests()
        #expect(model.pollTask == nil)
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(model.pollTask != nil)
    }

    /// Unreachable: probed again when the network comes back, and online again once the server answers.
    @Test func probesWhenTheNetworkReturns() async throws {
        let network = FakeNetwork(.wifi)
        let model = makeModel(fetcher: FakeFetcher(), network: network)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        network.status = noNetwork
        transport.setDown(["192.168.1.2"], with: .notConnectedToInternet)
        _ = try? await model.request { try await $0.albumList(.newest, size: 1, offset: 0) }
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
}
