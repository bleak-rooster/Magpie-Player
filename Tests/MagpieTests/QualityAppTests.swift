import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Observation
import Playback
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let cellular = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)

@MainActor @Observable
final class FakeNetwork: NetworkStatusProviding {
    var status: NetworkStatus
    init(_ status: NetworkStatus = .wifi) { self.status = status }
}

/// Polls `condition` until it holds or the deadline passes (no fixed sleeps).
@MainActor
private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Suite(.serialized) struct QualityAppTests {
    let transport = HostSwitchTransport()
    let engine = FakeEngine()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "QualityAppTests.\(UUID().uuidString)")!

    init() {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/rest/scrobble", body: ok)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
    }

    func signedIn(_ status: NetworkStatus) async throws -> (AppModel, FakeEngine, FakeNetwork) {
        let network = FakeNetwork(status)
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport,
                             engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: network)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        return (model, engine, network)
    }

    func tearDown(_ model: AppModel) {
        model.signOut()
        store.clear()
    }

    func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func song(_ id: String) -> Song { PlayerTests.song(id) }

    @Test func signOutCancelsTheSleepTimer() async throws {
        let (model, engine, _) = try await signedIn(.wifi)
        model.play([song("s1"), song("s2")], startAt: 0)
        model.sleepTimer.start(.m15)
        #expect(model.sleepTimer.mode != .off)
        model.sleepTimer.start(.endOfSong)
        model.signOut(); store.clear()
        await model.sleepTimer.settled()
        #expect(model.sleepTimer.mode == .off && !model.player.stopsAfterCurrent && model.player.volume == 1)
        #expect(engine.setVolumeCalls.isEmpty || engine.setVolumeCalls.last == 1)
    }

    @Test func wifiUsesOriginalRaw() async throws {
        let (model, engine, _) = try await signedIn(.wifi)
        defer { tearDown(model) }
        model.play([song("s1")], startAt: 0)
        let q = query(engine.setItemsCalls.last!.items[0].1)
        #expect(q["format"] == "raw" && q["maxBitRate"] == nil)
    }

    @Test func cellularUsesAAC160() async throws {
        let (model, engine, _) = try await signedIn(cellular)
        defer { tearDown(model) }
        model.play([song("s1")], startAt: 0)
        let q = query(engine.setItemsCalls.last!.items[0].1)
        #expect(q["format"] == "aac" && q["maxBitRate"] == "160")
    }

    @Test func lowDataModeOnWifiUsesMobileQuality() async throws {
        let (model, engine, _) = try await signedIn(NetworkStatus(isConnected: true, isCellular: false, isConstrained: true))
        defer { tearDown(model) }
        model.play([song("s1")], startAt: 0)
        let q = query(engine.setItemsCalls.last!.items[0].1)
        #expect(q["format"] == "aac" && q["maxBitRate"] == "160")
    }

    @Test func preferenceChangeAppliesToUpcoming() async throws {
        let (model, engine, _) = try await signedIn(.wifi)
        defer { tearDown(model) }
        model.play([song("s1"), song("s2")], startAt: 0)
        model.updatePreferences { $0.playback.wifi = .mp3_320 }
        let items = engine.setItemsCalls.last!.items
        #expect(query(items[0].1)["format"] == "raw" && query(items[1].1)["format"] == "mp3" && query(items[1].1)["maxBitRate"] == "320")
    }

    @Test func replayGainFollowsThePreference() async throws {
        let (model, engine, _) = try await signedIn(.wifi)
        defer { tearDown(model) }
        var loud = song("s1")
        loud.replayGain = ReplayGain(trackGain: -6, albumGain: -9)
        model.play([loud], startAt: 0)
        let id = model.player.queue.current!.id
        #expect(abs((engine.setVolumesCalls.last?[id] ?? 1) - 0.501187) < 0.0001, "Track by default")
        model.updatePreferences { $0.playback.replayGain = .album }
        #expect(abs((engine.setVolumesCalls.last?[id] ?? 1) - 0.354813) < 0.0001)
        model.updatePreferences { $0.playback.replayGain = .off }
        #expect(engine.setVolumesCalls.last?[id] == 1, "the playing song is re-levelled too")
    }

    @Test func networkChangeRebuildsUpcomingOnly() async throws {
        let (model, engine, network) = try await signedIn(.wifi)
        defer { tearDown(model) }
        model.play([song("s1"), song("s2")], startAt: 0)
        network.status = cellular
        #expect(await eventually { query(engine.setItemsCalls.last!.items[1].1)["format"] == "aac" })
        #expect(query(engine.setItemsCalls.last!.items[0].1)["format"] == "raw")
        #expect(engine.seeks.isEmpty)
    }

    @Test func transcodeHintShownOncePerSession() async throws {
        let (model, engine, _) = try await signedIn(cellular)
        defer { tearDown(model) }
        model.play([song("s1"), song("s2")], startAt: 0)
        model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))
        #expect(await eventually { model.playbackHint == AppModel.transcodeHint })
        #expect(query(engine.setItemsCalls.last!.items[0].1)["format"] == "raw")
        model.dismissPlaybackHint()
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))
        model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))
        #expect(model.player.lastFallbackSongId == "s2")
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.playbackHint == nil, "once per session")
    }

    /// Loaded on Wi-Fi Original, then the network turns cellular: the playing stream is raw already, so a failure is
    /// no transcode failure. No fallback, no hint; the player pauses with its error.
    @Test func rawStreamFailingAfterNetworkTurnsCellularIsNotAFallback() async throws {
        let (model, engine, network) = try await signedIn(.wifi)
        defer { tearDown(model) }
        model.play([song("s1"), song("s2")], startAt: 0)
        network.status = cellular
        #expect(await eventually { model.currentStreamQuality == .aac160 && self.query(engine.setItemsCalls.last!.items[1].1)["format"] == "aac" })
        model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.playbackHint == nil && model.player.lastFallbackSongId == nil)
        #expect(!model.player.isPlaying && model.player.lastError != nil)
    }

    /// Loaded on cellular AAC, then Wi-Fi Original: the playing stream is a transcode, so its failure falls back.
    @Test func aacStreamFailingAfterNetworkTurnsWifiFallsBack() async throws {
        let (model, engine, network) = try await signedIn(cellular)
        defer { tearDown(model) }
        model.play([song("s1"), song("s2")], startAt: 0)
        network.status = .wifi
        #expect(await eventually { model.currentStreamQuality == .original })
        model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))
        #expect(await eventually { model.playbackHint == AppModel.transcodeHint })
        #expect(query(engine.setItemsCalls.last!.items[0].1)["format"] == "raw")
        #expect(model.player.lastError == nil)
    }

    @Test func networkStatusPicksQuality() {
        let prefs = PlaybackPreferences.defaultValue
        #expect(prefs.quality(for: .wifi) == .original)
        #expect(prefs.quality(for: cellular) == .aac160)
    }
}
