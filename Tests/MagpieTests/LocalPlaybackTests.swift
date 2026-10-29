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
private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// The same, for a condition that has to await (the audio store).
@MainActor
private func eventually(_ seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Task 13: songs on the phone play from the phone, upcoming songs are pre-downloaded, and the cache is kept tidy.
@MainActor @Suite(.serialized) final class LocalPlaybackTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "LocalPlaybackTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "LocalPlaybackTests.\(UUID().uuidString)")!
    let engine = FakeEngine()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedInModel(fetcher: FakeFetcher) async throws -> AppModel {
        let transport = HostSwitchTransport()
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: engine, defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: fetcher)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        return model
    }

    func song(_ id: String) -> Song { PlayerTests.song(id) }

    /// The song ids the fetcher was asked for, in order.
    func fetchedIds(_ f: FakeFetcher) -> [String] {
        f.urls.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value }
    }

    // MARK: - The brief's tests

    @Test func localFileUsedWhenPresent() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 0 }
        model.download([song("s2")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2")], startAt: 0)
        let items = engine.setItemsCalls.last!.items
        #expect(!items[0].1.isFileURL && items[1].1.isFileURL)
        #expect(items[1].1 == model.downloads!.localFiles["s2"])
    }

    @Test func completedPreDownloadSwapsOnlyUpcoming() async throws {
        let f = FakeFetcher(); f.hold(after: 0)
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s1"), song("s2")], startAt: 0)
        let first = engine.setItemsCalls.last!.items
        #expect(!first[1].1.isFileURL)
        #expect(await eventually { f.inFlight == 1 })
        f.release(); await model.downloads!.settled()
        #expect(await eventually { self.engine.setItemsCalls.last!.items[1].1.isFileURL })
        #expect(engine.setItemsCalls.last!.items[0].1 == first[0].1 && engine.seeks.isEmpty)
    }

    @Test func preDownloadsAheadByN() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 2 }
        model.play((1...5).map { song("s\($0)") }, startAt: 0)
        #expect(await eventually { f.urls.count >= 2 })
        await model.downloads!.settled()
        #expect(fetchedIds(f) == ["s2", "s3"])
        #expect(f.urls.allSatisfy { $0.query?.contains("format=raw") == true }, "Wi-Fi quality")
        #expect(await model.downloads!.store.entry(songId: "s2")?.kind == .cache)
    }

    @Test func cacheRemovedAfterPlayWhenKeepOff() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 1; $0.downloads.keepRecentlyPlayed = false }
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") != nil })
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // now on s2
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // now on s3
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") == nil })
        #expect(await eventually { model.downloads!.localFiles["s2"] == nil }, "the mirror follows")
    }

    @Test func currentNeverEvicted() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.cacheLimitOverride = 1
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s0"), song("s1")], startAt: 0)
        #expect(await eventually { await model.downloads!.store.entry(songId: "s1") != nil })
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // s1 (cached) is current
        try await Task.sleep(for: .milliseconds(100))
        #expect(await model.downloads!.store.entry(songId: "s1") != nil)
    }

    // MARK: - Beyond the brief

    /// Keep recently played (the default): a played pre-download stays, and is evicted, least recently played first,
    /// only once the cache is over its limit.
    @Test func playedCacheKeptAndEvictedOverLimit() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s1"), song("s2"), song("s3"), song("s4")], startAt: 0)
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") != nil })
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // s2
        #expect(await eventually { await model.downloads!.store.entry(songId: "s3") != nil })
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // s3
        #expect(await eventually { await model.downloads!.store.entry(songId: "s4") != nil })
        #expect(await model.downloads!.store.entry(songId: "s2") != nil, "kept while under the limit")
        model.cacheLimitOverride = 2000   // two 1000-byte songs
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // s4: s2 played longest ago goes
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") == nil })
        #expect(await model.downloads!.store.entry(songId: "s3") != nil)
        #expect(await model.downloads!.store.entry(songId: "s4") != nil)
    }

    /// Downloads are never removed by cache upkeep, keep recently played or not.
    @Test func downloadsSurviveCacheUpkeep() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.cacheLimitOverride = 1
        model.updatePreferences { $0.downloads.preDownload = 0; $0.downloads.keepRecentlyPlayed = false }
        model.download([song("s1"), song("s2")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await model.downloads!.store.entry(songId: "s1")?.kind == .download)
        #expect(await model.downloads!.store.entry(songId: "s2")?.kind == .download)
    }

    /// ReplayGain (T9) levels a song played from the phone just as when streamed.
    @Test func replayGainAppliesToLocalSongs() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 0 }
        var loud = song("s1")
        loud.replayGain = ReplayGain(trackGain: -6)
        model.download([loud], reason: .song); await model.downloads!.settled()
        model.play([loud], startAt: 0)
        let item = try #require(engine.setItemsCalls.last?.items.first)
        #expect(item.1.isFileURL)
        let volume = try #require(engine.setVolumesCalls.last?[item.0])
        #expect(abs(volume - 0.501) < 0.01)
    }

    /// Engine window (QC): K is the pre-download count when that is more than 3, up to 10.
    @Test func engineWindowFollowsPreDownload() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 0 }
        #expect(model.player.lookahead == 3)
        model.updatePreferences { $0.downloads.preDownload = 6 }
        #expect(model.player.lookahead == 6)
        model.updatePreferences { $0.downloads.preDownload = 10 }
        model.play((1...20).map { song("s\($0)") }, startAt: 0)
        #expect(engine.setItemsCalls.last!.items.count == 11)
    }

    /// A downloaded song plays from its file (no network needed); a failure there has no server original to fall back to.
    @Test func localFileFailureHasNoServerFallback() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 0 }
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let file = try #require(model.downloads!.localFiles["s1"])
        model.play([song("s1")], startAt: 0)
        #expect(engine.setItemsCalls.last!.items[0].1 == file)
        model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))
        #expect(model.player.lastFallbackSongId == nil, "no server fallback for a local file")
    }

    /// T7/T8 contract: the Navidrome original check reads the stream's format and cap, not its auth.
    @Test func navidromeOriginalCheckIgnoresAuth() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let box = ClientBox()
        box.set(model.session?.client)
        let urls = NavidromeStreamURLs(box: box, quality: QualityBox(.aac160))
        let original = try #require(urls.originalURL(for: song("s1")))
        #expect(urls.isOriginal(original))
        #expect(!urls.isOriginal(urls.streamURL(for: song("s1"))), "a transcode")
        var resigned = try #require(URLComponents(url: original, resolvingAgainstBaseURL: false))
        resigned.queryItems = resigned.queryItems?.map { $0.name == "s" || $0.name == "t" ? URLQueryItem(name: $0.name, value: "new") : $0 }
        #expect(urls.isOriginal(try #require(resigned.url)), "signed again after a re-login")
        #expect(!urls.isOriginal(URL(filePath: "/tmp/song.mp3")))
    }
}
