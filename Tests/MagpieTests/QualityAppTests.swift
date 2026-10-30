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

    /// R5: each preset's stream URL asks for its format at its bit rate, on Wi-Fi and on mobile data alike.
    @Test func streamURLCarriesThePresetBitRate() async throws {
        let (model, engine, network) = try await signedIn(.wifi)
        defer { tearDown(model) }
        let expected: [(StreamQuality, String, String)] = [
            (.mp3High, "mp3", "320"), (.mp3Medium, "mp3", "192"), (.mp3Low, "mp3", "128"),
            (.aacHigh, "aac", "256"), (.aacMedium, "aac", "160"), (.aacLow, "aac", "96"),
            (.opusHigh, "opus", "320"), (.opusMedium, "opus", "160"), (.opusLow, "opus", "96"),
        ]
        for (quality, format, rate) in expected {
            model.updatePreferences { $0.playback.wifi = quality }
            model.play([song("s1")], startAt: 0)
            let q = query(engine.setItemsCalls.last!.items[0].1)
            #expect(q["format"] == format && q["maxBitRate"] == rate, "\(quality)")
        }
        network.status = cellular
        model.updatePreferences { $0.playback.cellular = .mp3Low }
        #expect(await eventually { model.currentStreamQuality == .mp3Low })
        model.play([song("s2")], startAt: 0)
        let q = query(engine.setItemsCalls.last!.items[0].1)
        #expect(q["format"] == "mp3" && q["maxBitRate"] == "128")
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
        model.updatePreferences { $0.playback.wifi = .mp3High }
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
        #expect(await eventually { model.currentStreamQuality == .aacMedium && self.query(engine.setItemsCalls.last!.items[1].1)["format"] == "aac" })
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

    /// D45: Opus streams are asked for chunked (no estimate) at the preset's bit rate.
    @Test func opusPresetStreamsAsOggOpus() async throws {
        let (model, engine, _) = try await signedIn(.wifi)
        defer { tearDown(model) }
        model.updatePreferences { $0.playback.wifi = .opusLow }
        model.play([song("s1")], startAt: 0)
        let q = query(engine.setItemsCalls.last!.items[0].1)
        #expect(q["format"] == "opus" && q["maxBitRate"] == "96" && q["estimateContentLength"] == nil)
    }

    /// D45: Ogg engine durations are estimates, so the scrubber, the remaining time and the scrobble threshold keep
    /// the API's song duration (200 s here) when the engine reports another.
    @Test func opusEngineDurationDoesNotReplaceTheAPIDuration() async throws {
        let (model, engine, _) = try await signedIn(.wifi)
        defer { tearDown(model) }
        model.updatePreferences { $0.playback.wifi = .opusMedium }
        model.play([song("s1"), song("s2")], startAt: 0)
        #expect(query(engine.setItemsCalls.last!.items[0].1)["format"] == "opus")
        let entry = try #require(model.player.queue.current?.id)
        model.player.listen(entry, from: 0, to: 10, duration: 207.4)
        #expect(model.player.duration == 200, "the API duration, not the Ogg estimate")
        model.player.listen(entry, from: 10, to: 101, duration: 207.4)   // past 50 % of 200, short of 50 % of 207.4
        await model.player.waitForPendingScrobbles()
        let submissions = transport.inner.requests.compactMap(\.url).filter {
            $0.path.hasSuffix("/rest/scrobble") && $0.absoluteString.contains("submission=true")
        }
        #expect(submissions.count == 1, "the threshold is half of the API's 200 s")
    }

    /// With no API duration the engine's is all there is, so it shows.
    @Test func engineDurationFillsInWhenTheAPIHasNone() async throws {
        let (model, _, _) = try await signedIn(.wifi)
        defer { tearDown(model) }
        model.play([PlayerTests.song("s1", duration: 0)], startAt: 0)
        let entry = try #require(model.player.queue.current?.id)
        model.player.handle(.time(entry, 5, duration: 187.5))
        #expect(model.player.duration == 187.5)
    }

    /// The pickers list the qualities by codec, in enum order.
    @Test func pickerGroupsFollowCodecOrder() {
        #expect(StreamQuality.groups.map { StreamQualityOptions.heading(forFormat: $0.format) } == ["Original", "AAC", "Opus", "MP3"])
        #expect(StreamQuality.groups[2].qualities.map(\.title) == [
            "High · 320 kbps", "Medium · 160 kbps", "Low · 96 kbps"])
    }

    /// Opus falls back to Original like AAC.
    @Test func opusStreamFailingFallsBackToOriginal() async throws {
        let (model, engine, _) = try await signedIn(.wifi)
        defer { tearDown(model) }
        model.updatePreferences { $0.playback.wifi = .opusLow }
        model.play([song("s1"), song("s2")], startAt: 0)
        model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))
        #expect(await eventually { model.playbackHint == AppModel.transcodeHint })
        #expect(query(engine.setItemsCalls.last!.items[0].1)["format"] == "raw")
        #expect(model.player.lastError == nil)
    }

    @Test func networkStatusPicksQuality() {
        let prefs = PlaybackPreferences.defaultValue
        #expect(prefs.quality(for: .wifi) == .original)
        #expect(prefs.quality(for: cellular) == .aacMedium)
    }
}
