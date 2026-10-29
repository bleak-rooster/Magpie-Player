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

    func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func song(_ id: String) -> Song { PlayerTests.song(id) }

    @Test func wifiUsesOriginalRaw() async throws {
        let (model, engine, _) = try await signedIn(.wifi)
        model.play([song("s1")], startAt: 0)
        let q = query(engine.setItemsCalls.last!.items[0].1)
        #expect(q["format"] == "raw" && q["maxBitRate"] == nil)
    }

    @Test func cellularUsesAAC160() async throws {
        let (model, engine, _) = try await signedIn(cellular)
        model.play([song("s1")], startAt: 0)
        let q = query(engine.setItemsCalls.last!.items[0].1)
        #expect(q["format"] == "aac" && q["maxBitRate"] == "160")
    }

    @Test func lowDataModeOnWifiUsesMobileQuality() async throws {
        let (model, engine, _) = try await signedIn(NetworkStatus(isConnected: true, isCellular: false, isConstrained: true))
        model.play([song("s1")], startAt: 0)
        let q = query(engine.setItemsCalls.last!.items[0].1)
        #expect(q["format"] == "aac" && q["maxBitRate"] == "160")
    }

    @Test func preferenceChangeAppliesToUpcoming() async throws {
        let (model, engine, _) = try await signedIn(.wifi)
        model.play([song("s1"), song("s2")], startAt: 0)
        model.updatePreferences { $0.playback.wifi = .mp3_320 }
        let items = engine.setItemsCalls.last!.items
        #expect(query(items[0].1)["format"] == "raw" && query(items[1].1)["format"] == "mp3" && query(items[1].1)["maxBitRate"] == "320")
    }

    @Test func networkChangeRebuildsUpcomingOnly() async throws {
        let (model, engine, network) = try await signedIn(.wifi)
        model.play([song("s1"), song("s2")], startAt: 0)
        network.status = cellular
        #expect(await eventually { query(engine.setItemsCalls.last!.items[1].1)["format"] == "aac" })
        #expect(query(engine.setItemsCalls.last!.items[0].1)["format"] == "raw")
        #expect(engine.seeks.isEmpty)
    }

    @Test func transcodeHintShownOncePerSession() async throws {
        let (model, engine, _) = try await signedIn(cellular)
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

    @Test func networkStatusPicksQuality() {
        let prefs = PlaybackPreferences.defaultValue
        #expect(prefs.quality(for: .wifi) == .original)
        #expect(prefs.quality(for: cellular) == .aac160)
    }
}
