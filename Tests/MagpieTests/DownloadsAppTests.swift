import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

/// Polls `condition` until it holds or the deadline passes (no fixed sleeps).
@MainActor
private func eventually(_ seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

extension AppModel {
    /// Tests: answers `path` with a Subsonic `ok` body holding `fragment` (the fixture's `HostSwitchTransport`).
    func transport(stub path: String, _ fragment: String) {
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","# + fragment + "}}"
        (transport as? HostSwitchTransport)?.inner.stub(pathSuffix: path, body: Data(body.utf8))
    }
}

@MainActor @Suite(.serialized) final class DownloadsAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "DownloadsAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "DownloadsAppTests.\(UUID().uuidString)")!

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedInModel(fetcher: FakeFetcher, user: String = "admin") async throws -> AppModel {
        let transport = HostSwitchTransport()
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: fetcher)
        try await model.signIn(urls: [home], username: user, password: "pw")
        return model
    }

    func song(_ id: String) -> Song { PlayerTests.song(id) }

    // MARK: - The brief's tests

    @Test func signOutRemovesScopeAudio() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let dir = try #require(model.downloads?.storeDirectory)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        model.signOut()
        #expect(model.downloads == nil)
        #expect(await eventually { !FileManager.default.fileExists(atPath: dir.path) })
    }

    @Test func lateCompletionAfterSignOutIsDiscarded() async throws {           // Review Focus 3
        let f = FakeFetcher(); f.hold(after: 0)
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1")], reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        let oldDir = try #require(model.downloads?.storeDirectory)
        model.signOut()
        try await model.signIn(urls: [home], username: "other", password: "pw")
        let newDir = try #require(model.downloads?.storeDirectory)
        #expect(newDir != oldDir)
        f.release(); try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
        #expect(await model.downloads!.store.entry(songId: "s1") == nil)
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func fetchThatIgnoresCancellationStillLandsNowhere() async throws {
        let f = FakeFetcher(); f.hold(after: 0); f.ignoresCancellation = true
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1")], reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        let oldDir = try #require(model.downloads?.storeDirectory)
        model.signOut()
        try await model.signIn(urls: [home], username: "other", password: "pw")
        model.download([song("s2")], reason: .song)
        f.release()
        await model.downloads!.settled()
        #expect(await eventually { !FileManager.default.fileExists(atPath: oldDir.path) })
        #expect(await model.downloads!.store.entry(songId: "s1") == nil)
        #expect(Set(model.downloads!.localFiles.keys) == ["s2"])
        #expect(!f.written.contains { FileManager.default.fileExists(atPath: $0.path) }, "no temporary file left")
    }

    @Test func albumDownloadSavesItsCover() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1"), song("s2")], reason: .album("a1"), coverArtId: "al-1"); await model.downloads!.settled()
        let cover = try #require(f.urls.first { $0.path.hasSuffix("/rest/getCoverArt") })
        #expect(URLComponents(url: cover, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "size" }?.value == "600")
        #expect(await model.downloads!.store.coverURL(coverArtId: "al-1") != nil)
    }

    @Test func playlistRefreshOnOpen() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let p = Playlist(id: "p1", name: "Mix", songCount: 2, duration: 400, coverArtId: "pl-1")
        model.download([song("s1"), song("s2")], reason: .playlist("p1"),
                       playlist: DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: "pl-1", songIds: ["s1", "s2"], savedAt: .now),
                       coverArtId: "pl-1")
        await model.downloads!.settled()
        await model.refreshDownloadedPlaylist(p, songs: [song("s2"), song("s3")])
        await model.downloads!.settled()
        #expect(Set(model.downloads!.localFiles.keys) == ["s2", "s3"])
        #expect(await model.downloads!.store.playlists().first?.songIds == ["s2", "s3"])
    }

    @Test func favouritesToggle() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.transport(stub: "/rest/getStarred2", #""starred2":{"song":[{"id":"s7","title":"Seven"},{"id":"s8","title":"Eight"}]}"#)
        await model.setKeepFavourites(true); await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s7")?.reasons == [.favourites])
        #expect(Set(model.downloads!.localFiles.keys) == ["s7", "s8"])
        await model.setKeepFavourites(false)
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func reDownloadAtNewQuality() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        model.updatePreferences { $0.downloads.quality = .mp3_320 }
        await model.redownloadAtCurrentQuality(); await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s1")?.quality == .mp3_320)
        let audio = try FileManager.default.contentsOfDirectory(atPath: model.downloads!.storeDirectory.path)
            .filter { $0.hasSuffix(".mp3") || $0.hasSuffix(".flac") }
        #expect(audio.count == 1)
    }

    // MARK: - More

    @Test func playlistNotDownloadedIsNotRefreshed() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        await model.downloads!.settled()
        let p = Playlist(id: "p9", name: "Other", songCount: 1, duration: 200)
        await model.refreshDownloadedPlaylist(p, songs: [song("s1")])
        await model.downloads!.settled()
        #expect(f.urls.isEmpty)
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func signInAgainToTheSameAccountKeepsNewDownloads() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let dir = try #require(model.downloads?.storeDirectory)
        model.signOut()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        #expect(model.downloads?.storeDirectory == dir, "the same account's scope")
        model.download([song("s2")], reason: .song); await model.downloads!.settled()
        #expect(Set(model.downloads!.localFiles.keys) == ["s2"], "the old audio was erased, the new kept")
        #expect(await model.downloads!.store.entry(songId: "s2") != nil)
    }

    @Test func songDownloadAndRemove() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1"), song("s2")], reason: .album("a1")); await model.downloads!.settled()
        #expect(model.downloadStatus(["s1", "s2"]) == .downloaded)
        await model.removeSongDownload("s1")
        #expect(Set(model.downloads!.localFiles.keys) == ["s2"])
        #expect(model.downloadStatus(["s1"]) == .none)
        await model.removeDownload(.album("a1"))
        #expect(model.downloads!.localFiles.isEmpty)
        #expect(model.downloadStatus(["s1", "s2"]) == .none)
    }

    @Test func removeAllAndClearCache() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1")], reason: .song)
        model.downloads!.preDownload([song("c1")], quality: .original)
        await model.downloads!.settled()
        var usage = await model.storageUsage
        #expect(usage == AudioUsage(downloadBytes: 1000, cacheBytes: 1000))
        await model.removeAllDownloads()
        usage = await model.storageUsage
        #expect(usage == AudioUsage(downloadBytes: 0, cacheBytes: 1000))
        #expect(Set(model.downloads!.localFiles.keys) == ["c1"])
        await model.clearCache()
        usage = await model.storageUsage
        #expect(usage == AudioUsage(downloadBytes: 0, cacheBytes: 0))
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func keepFavouritesPreferenceDownloadsThem() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.transport(stub: "/rest/getStarred2", #""starred2":{"song":[{"id":"s7","title":"Seven"}]}"#)
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.keepFavourites = true }
        #expect(await eventually { model.downloads!.localFiles.keys.contains("s7") })
        model.updatePreferences { $0.downloads.keepFavourites = false }
        #expect(await eventually { model.downloads!.localFiles.isEmpty })
    }

    @Test func storageSummaryAndUsageText() {
        #expect(DownloadsSettingsView.summary(.defaultValue) == "2 GB cache · 3 ahead")
        var prefs = DownloadPreferences.defaultValue
        prefs.cacheLimit = .mb500; prefs.preDownload = 0
        #expect(DownloadsSettingsView.summary(prefs) == "500 MB cache · none ahead")
        let text = DownloadsSettingsView.usageText(AudioUsage(downloadBytes: 1_200_000_000, cacheBytes: 340_000_000))
        #expect(text == "Downloads 1.2 GB · Cache 340 MB")
    }

    @Test func notSignedInHasNoDownloads() async {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: HostSwitchTransport(),
                             probeTransport: HostSwitchTransport(), engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        #expect(model.downloads == nil)
        #expect(model.downloadStatus(["s1"]) == .none)
        #expect(await model.storageUsage == AudioUsage(downloadBytes: 0, cacheBytes: 0))
    }
}
