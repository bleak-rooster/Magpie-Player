import AVFoundation
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
private let extensionsJSON = Data(#"""
{"subsonic-response":{"status":"ok","version":"1.16.1","openSubsonicExtensions":[{"name":"songLyrics","versions":[1]},{"name":"transcodeOffset","versions":[1]}]}}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let cellular = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)
private let disconnected = NetworkStatus(isConnected: false, isCellular: false, isConstrained: false)

/// Round 27 P (owner items 10 and 11, 2026-11-14): Now Playing's hint goes with its song (D276); a dropped converted
/// stream picks up with "Connection dropped…" (D278) and seeks start the conversion there (D281) where the server
/// advertises `transcodeOffset`; pre-downloads give way to a converted stream on mobile data (D280); the current song's
/// item is never reloaded by a change of where the songs after it come from (D282).
///
/// Four setups: everything here is playback against Navidrome alone; Lidarr, Aurral and ListenBrainz play no part in it,
/// so it behaves the same in all four (no control appears or hides by setup).
@MainActor @Suite(.serialized) final class Round27PlaybackAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "Round27PlaybackAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "Round27PlaybackAppTests.\(UUID().uuidString)")!
    let engine = FakeEngine()
    let transport = HostSwitchTransport()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedIn(_ status: NetworkStatus, transcodeOffset: Bool = false, fetcher: (any AudioFetching)? = nil)
        async throws -> (AppModel, FakeNetwork) {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/rest/scrobble", body: ok)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        if transcodeOffset { transport.inner.stub(pathSuffix: "/rest/getOpenSubsonicExtensions", body: extensionsJSON) }
        let network = FakeNetwork(status)
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: fetcher == nil ? nil : tmp, transport: transport,
                             probeTransport: transport, engine: engine, defaults: defaults, systemNowPlaying: false,
                             notifications: false, network: network, audioFetcher: fetcher ?? FakeFetcher())
        model.cacheEvictionDebounce = .milliseconds(10)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        if let downloads = model.downloads { await downloads.settled() }
        return (model, network)
    }

    func song(_ id: String) -> Song { PlayerTests.song(id) }

    func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
    }

    var currentSent: URL? { engine.setItemsCalls.last { !$0.items.isEmpty }?.items.first?.1 }

    // MARK: - D276: the hint goes with its song

    @Test func hint_clearsWhenTheNextSongStarts() async throws {
        let (model, _) = try await signedIn(cellular)
        defer { model.signOut() }
        model.play([song("s1"), song("s2")], startAt: 0)
        model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))   // couldn't convert: the original
        #expect(await eventually { model.playbackHint == AppModel.transcodeHint })
        model.player.next()
        #expect(await eventually { model.playbackHint == nil }, "the next song starts without the last one's hint")
        #expect(model.player.lastError == nil)
    }

    @Test func hint_clearsOnAGaplessMoveToo() async throws {
        let (model, _) = try await signedIn(cellular)
        defer { model.signOut() }
        model.play([song("s1"), song("s2")], startAt: 0)
        model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))
        #expect(await eventually { model.playbackHint == AppModel.transcodeHint })
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))
        #expect(await eventually { model.playbackHint == nil })
    }

    @Test func hint_staysForItsOwnSong() async throws {
        let (model, _) = try await signedIn(cellular)
        defer { model.signOut() }
        model.play([song("s1"), song("s2")], startAt: 0)
        let id = model.player.queue.current!.id
        model.player.handle(.failed(id, "cannot open"))
        #expect(await eventually { model.playbackHint == AppModel.transcodeHint })
        model.player.listen(id, from: 0, to: 5)
        model.player.addToEnd([song("s3")])
        model.player.seek(3)
        // Give the watcher every chance to act on those changes, then check it didn't.
        #expect(await eventually(0.3) { model.playbackHint == nil } == false, "the song it was raised for still plays")
        #expect(model.playbackHintSongId == "s1")
    }

    // MARK: - D278: a dropped converted stream

    @Test func network_retryHintShowsThenClearsOnTick() async throws {
        let (model, _) = try await signedIn(cellular, transcodeOffset: true)
        defer { model.signOut() }
        model.play([song("s1"), song("s2")], startAt: 0)
        #expect(await eventually { model.player.startsConversionsPartWay() }, "the extension is read once a song streams")
        let id = model.player.queue.current!.id
        model.player.listen(id, from: 0, to: 30)
        engine.causes[id] = .network
        model.player.handle(.failed(id, "The network connection was lost."))
        #expect(await eventually { model.playbackHint == AppModel.reconnectingHint })
        #expect(model.player.lastError == nil && model.player.lastFallbackSongId == nil)
        #expect(await eventually { self.query(self.currentSent)["timeOffset"] == "30" }, "same stream from 30 s")
        #expect(query(currentSent)["format"] == "aac" && model.player.position == 30)
        model.player.handle(.time(id, 0.5, duration: nil))
        #expect(await eventually { model.playbackHint == nil }, "sound again: the hint goes")
        #expect(model.player.position == 30.5)
    }

    @Test func network_retryHintGoesWithItsSong() async throws {
        let (model, _) = try await signedIn(cellular)
        defer { model.signOut() }
        model.play([song("s1"), song("s2")], startAt: 0)
        let id = model.player.queue.current!.id
        model.player.listen(id, from: 0, to: 30)
        engine.causes[id] = .network
        model.player.handle(.failed(id, "The network connection was lost."))
        #expect(await eventually { model.playbackHint == AppModel.reconnectingHint })
        model.player.next()
        #expect(await eventually { model.playbackHint == nil })
    }

    @Test func network_noConnectionStopsWithTheError() async throws {
        let (model, network) = try await signedIn(cellular)
        defer { model.signOut() }
        model.play([song("s1"), song("s2")], startAt: 0)
        let id = model.player.queue.current!.id
        model.player.listen(id, from: 0, to: 30)
        network.status = disconnected
        engine.causes[id] = .network
        model.player.handle(.failed(id, "The Internet connection appears to be offline."))
        #expect(model.player.lastError != nil && !model.player.isPlaying)
        #expect(model.player.reconnectingSongId == nil && model.player.lastFallbackSongId == nil)
    }

    // MARK: - D281: seeks start the conversion there

    @Test func seek_convertedReloadsWithTimeOffset() async throws {
        let (model, _) = try await signedIn(cellular, transcodeOffset: true)
        defer { model.signOut() }
        model.play([song("s1"), song("s2")], startAt: 0)
        #expect(await eventually { model.player.startsConversionsPartWay() })
        model.player.seek(95.6)
        #expect(query(currentSent)["timeOffset"] == "95" && engine.seeks.isEmpty)
        #expect(model.player.position == 95)
    }

    @Test func seek_withoutTheExtensionIsTodays() async throws {
        let (model, _) = try await signedIn(cellular)
        defer { model.signOut() }
        model.play([song("s1"), song("s2")], startAt: 0)
        model.player.seek(95.6)
        #expect(engine.seeks == [95.6] && query(currentSent)["timeOffset"] == nil)
    }

    // MARK: - D280: pre-downloads give way on mobile data

    func fetchedIds(_ f: FakeFetcher) -> [String] {
        f.urls.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value }
    }

    @Test func preDownload_waitsFifteenSeconds() async throws {
        let f = FakeFetcher()
        let (model, _) = try await signedIn(cellular, fetcher: f)
        defer { model.signOut() }
        model.updatePreferences { $0.downloads.preDownload = 3 }
        model.play(["s1", "s2", "s3", "s4"].map(song), startAt: 0)
        #expect(await eventually { model.preDownloadSnapshot?.current?.id == model.player.queue.current?.id })
        await model.downloads!.settled()
        #expect(fetchedIds(f).isEmpty, "nothing while the converted song's first 15 s play")
        model.player.listen(model.player.queue.current!.id, from: 0, to: 15.5)
        #expect(await eventually { self.fetchedIds(f).first == "s2" })
    }

    @Test func preDownload_oneAtATimeOnMobileWhileConverted() async throws {
        let f = FakeFetcher()
        f.hold(after: 0)
        let (model, _) = try await signedIn(cellular, fetcher: f)
        defer { model.signOut() }
        model.updatePreferences { $0.downloads.preDownload = 3 }
        model.play(["s1", "s2", "s3", "s4"].map(song), startAt: 0)
        model.player.listen(model.player.queue.current!.id, from: 0, to: 20)
        #expect(await eventually { f.inFlight == 1 })
        #expect(await eventually(0.3) { f.inFlight > 1 } == false, "one at a time")
        f.release()
        #expect(await eventually { Set(self.fetchedIds(f)) == ["s2", "s3", "s4"] }, "each in turn")
        #expect(f.maxInFlight == 1)
    }

    /// Fix round 1 (I1): one at a time doesn't stop when one fails: the next song is still fetched.
    @Test func preDownload_aFailedOneLetsTheNextStart() async throws {
        let f = FakeFetcher()
        f.hold(after: 0)
        let (model, _) = try await signedIn(cellular, fetcher: f)
        defer { model.signOut() }
        model.updatePreferences { $0.downloads.preDownload = 3 }
        model.play(["s1", "s2", "s3", "s4"].map(song), startAt: 0)
        model.player.listen(model.player.queue.current!.id, from: 0, to: 20)
        #expect(await eventually { self.fetchedIds(f) == ["s2"] })
        f.failWith(URLError(.badServerResponse))
        f.release()
        #expect(await eventually { self.fetchedIds(f).contains("s3") }, "the next one starts after a failure too")
        #expect(f.maxInFlight == 1)
    }

    /// Fix round 2 (N1): when the limit loosens on a song change, the old plan's queued pre-downloads don't start: the
    /// song that just became current (queued while the last one held) is dropped first, and the new plan's start.
    @Test func preDownload_looseningOnASkipDoesntStartTheOldPlan() async throws {
        let f = FakeFetcher()
        let (model, network) = try await signedIn(cellular, fetcher: f)
        defer { model.signOut() }
        model.updatePreferences { $0.downloads.preDownload = 3 }
        model.play(["s1", "s2", "s3", "s4"].map(song), startAt: 0)
        #expect(await eventually { model.preDownloadSnapshot?.pacing == .hold })
        await model.downloads!.settled()
        #expect(fetchedIds(f).isEmpty, "s2, s3 and s4 wait while s1's first 15 s play")
        network.status = .wifi   // and in the same turn, a skip to s2
        model.player.next()
        #expect(await eventually { Set(self.fetchedIds(f)).isSuperset(of: ["s3", "s4"]) })
        #expect(!fetchedIds(f).contains("s2"), "the song now playing isn't pre-downloaded: \(fetchedIds(f))")
    }

    @Test func preDownload_wifiUnchanged() async throws {
        let f = FakeFetcher()
        f.hold(after: 0)
        let (model, _) = try await signedIn(.wifi, fetcher: f)
        defer { model.signOut() }
        model.updatePreferences { $0.downloads.preDownload = 3 }
        model.play(["s1", "s2", "s3", "s4"].map(song), startAt: 0)
        #expect(await eventually { f.inFlight == 2 }, "two at once from the start, as before")
        f.release()
    }

    @Test func preDownloadPacing_rules() {
        let aac = URL(string: "http://192.168.1.2:4533/rest/stream?id=1&maxBitRate=160&format=aac")!
        let raw = URL(string: "http://192.168.1.2:4533/rest/stream?id=1&format=raw")!
        let file = URL(filePath: "/tmp/magpie-r27/1.flac")
        typealias P = AppModel.PreDownloadPacing
        #expect(AppModel.preDownloadPacing(currentURL: aac, status: cellular, position: 3, ended: false) == P.hold)
        #expect(AppModel.preDownloadPacing(currentURL: aac, status: cellular, position: 15, ended: false) == P.oneAtATime)
        #expect(AppModel.preDownloadPacing(currentURL: aac, status: cellular, position: 3, ended: true) == P.oneAtATime,
                "a song shorter than 15 s: when it ends")
        let lowData = NetworkStatus(isConnected: true, isCellular: false, isConstrained: true)
        #expect(AppModel.preDownloadPacing(currentURL: aac, status: lowData, position: 3, ended: false) == P.hold)
        #expect(AppModel.preDownloadPacing(currentURL: aac, status: .wifi, position: 3, ended: false) == P.normal)
        #expect(AppModel.preDownloadPacing(currentURL: raw, status: cellular, position: 3, ended: false) == P.normal)
        #expect(AppModel.preDownloadPacing(currentURL: file, status: cellular, position: 3, ended: false) == P.normal)
        #expect(AppModel.preDownloadPacing(currentURL: nil, status: cellular, position: 3, ended: false) == P.normal)
        #expect(AppModel.cacheRunCap(P.normal) == nil)
        #expect(AppModel.cacheRunCap(P.oneAtATime) == 1)
        #expect(AppModel.cacheRunCap(P.hold) == 0)
    }

    // MARK: - D282: the current item is kept (real engine)

    /// A song plays; then its source changes and the songs are re-sent the way a landing pre-download, a finished
    /// download, a cache swap or a quality change does (`upcomingURLsChanged`; each is pinned at the player in
    /// `ErrorLifecycleTests.currentURL_neverResent`). The real engine keeps the very same item.
    @Test func currentURL_neverResentToTheEngine() async throws {
        let first = try AVQueueEngineTests.silentWAV(seconds: 4)
        let other = try AVQueueEngineTests.silentWAV(seconds: 4)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: other) }
        final class Files: StreamURLProvider {
            var urls: [String: URL] = [:]
            func streamURL(for song: Song) -> URL { urls[song.id] ?? URL(string: "about:blank")! }
        }
        let files = Files()
        files.urls = ["a": first, "b": other]
        let engine = AVQueueEngine(activateSession: {})
        let player = Player(engine: engine, scrobbler: FakeScrobbler(), urls: files)
        player.play([song("a"), song("b")], startAt: 0)
        let item = try #require(engine.currentItemIdentity)
        files.urls["a"] = other   // the current song's source is now another file
        player.upcomingURLsChanged()
        #expect(engine.currentItemIdentity == item, "the same AVPlayerItem plays on")
        #expect(engine.enqueuedItems.first?.url == first)
        player.play([], startAt: 0)
    }
}
