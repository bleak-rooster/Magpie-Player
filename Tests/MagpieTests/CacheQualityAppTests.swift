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
private let cell = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)

/// Round 13 item 7, wired into playback: the song that starts playing from the cache at the wrong quality is fetched
/// again, and its new copy is swapped in once it has finished playing (never mid-song).
@MainActor @Suite(.serialized) final class CacheQualityAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "CacheQualityAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "CacheQualityAppTests.\(UUID().uuidString)")!
    let engine = FakeEngine()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedInModel(fetcher: FakeFetcher, network: FakeNetwork) async throws -> AppModel {
        let transport = HostSwitchTransport()
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: engine, defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: network,
                             audioFetcher: fetcher)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        model.downloads!.loadPlayableForCheck = { _ in true }
        return model
    }

    func song(_ id: String) -> Song {
        Song(id: id, title: "T\(id)", artist: "A", album: "B", albumId: "al", duration: 200, suffix: "flac")
    }

    func rawFetches(_ f: FakeFetcher, _ id: String) -> Int {
        f.urls.count { $0.path.hasSuffix("/rest/stream") && $0.query?.contains("id=\(id)") == true
            && $0.query?.contains("format=raw") == true }
    }

    /// Cached at Opus 160 (pre-downloaded), then played with Wi-Fi set to Original: fetched again as the original,
    /// held while it plays, swapped in after.
    @Test func playingACachedSongAtTheWrongQualityReplacesItAfterThePlay() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f, network: FakeNetwork(.wifi))
        model.updatePreferences { $0.playback.wifi = .opusMedium; $0.downloads.preDownload = 2 }
        model.play([song("s0"), song("s1"), song("s2")], startAt: 0)
        let manager = try #require(model.downloads)
        #expect(await eventually { manager.localQualities["s1"] == .opusMedium && manager.localQualities["s2"] == .opusMedium })
        await manager.settled()
        model.updatePreferences { $0.playback.wifi = .original }
        #expect(rawFetches(f, "s1") == 0, "a cached song not playing is left alone")

        model.player.next()   // s1 plays from the cache, at Opus 160
        #expect(await eventually { manager.pendingCacheSwapSongId == "s1" })
        #expect(rawFetches(f, "s1") == 1)
        #expect(await manager.store.entry(songId: "s1")?.quality == .opusMedium, "never mid-song")

        model.player.next()   // s1 has finished: its new copy goes in
        #expect(await eventually { manager.localQualities["s1"] == .original })
        #expect(await manager.store.entry(songId: "s1")?.kind == .cache)
    }

    /// Cached at the mobile quality and playing on mobile data: nothing. Wi-Fi comes back: the playing song is fetched
    /// again at the Wi-Fi quality.
    @Test func aNetworkChangeWhilePlayingFetchesTheNewTarget() async throws {
        let f = FakeFetcher()
        let net = FakeNetwork(cell)
        let model = try await signedInModel(fetcher: f, network: net)
        model.updatePreferences {
            $0.playback.cellular = .opusMedium; $0.playback.wifi = .original
            $0.downloads.preDownload = 1; $0.downloads.overMobileData = false
        }
        model.play([song("s0"), song("s1")], startAt: 0)
        let manager = try #require(model.downloads)
        #expect(await eventually { manager.localQualities["s1"] == .opusMedium })
        await manager.settled()
        model.player.next()
        await manager.settled()
        #expect(rawFetches(f, "s1") == 0 && manager.pendingCacheSwapSongId == nil, "the copy matches mobile data")

        net.status = .wifi
        #expect(await eventually { manager.pendingCacheSwapSongId == "s1" })
        #expect(rawFetches(f, "s1") == 1)
    }

    /// On mobile data with mobile downloads off, a mismatched cached song is played as it is and never fetched.
    @Test func mobileDataOffNeverFetchesAReplacement() async throws {
        let f = FakeFetcher()
        let net = FakeNetwork(.wifi)
        let model = try await signedInModel(fetcher: f, network: net)
        model.updatePreferences { $0.playback.wifi = .opusMedium; $0.downloads.preDownload = 1 }
        model.play([song("s0"), song("s1")], startAt: 0)
        let manager = try #require(model.downloads)
        #expect(await eventually { manager.localQualities["s1"] == .opusMedium })
        await manager.settled()
        model.updatePreferences { $0.playback.cellular = .aacHigh; $0.downloads.overMobileData = false }
        net.status = cell
        model.player.next()
        await manager.settled()
        for _ in 0..<20 { await Task.yield() }
        #expect(manager.cacheRefreshSongId == nil && manager.pendingCacheSwapSongId == nil)
        #expect(!f.urls.contains { $0.query?.contains("id=s1") == true && $0.query?.contains("format=aac") == true })
    }
}
