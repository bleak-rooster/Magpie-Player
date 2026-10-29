import AVFoundation
import Foundation
import MagpieCore
import MagpieTestSupport
import MediaPlayer
import NavidromeKit
import Observation
import Playback
import Testing
@testable import Magpie

/// Verify V2: FLOWS.md §3c (playback and streaming) and §3d (Count plays), proved through the app's own wiring.
private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let away = URL(string: "https://music.example.com/navidrome")!

@MainActor
@Suite(.serialized) struct PlaybackFlowsVerifyTests {
    let transport = HostSwitchTransport()
    let engine = FakeEngine()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "PlaybackFlowsVerifyTests.\(UUID().uuidString)")!

    init() {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/rest/scrobble", body: ok)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, transport: transport, probeTransport: transport, engine: engine,
                 defaults: defaults, systemNowPlaying: false, notifications: false, network: FakeNetwork())
    }

    func tearDown(_ model: AppModel) {
        model.signOut()
        store.clear()
    }

    static func song(_ id: String, duration: TimeInterval = 200) -> Song {
        Song(id: id, title: "T\(id)", artist: "A", album: "B", duration: duration, libraryId: 1)
    }

    func scrobbleRequests() -> [URLComponents] {
        transport.inner.requests.compactMap { r in
            guard let url = r.url, url.path.hasSuffix("/rest/scrobble") else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)
        }
    }

    // MARK: - §3c Stream URL

    /// FLOWS §3c (0.0.1): on Wi-Fi with Original the app's stream URL is `rest/stream` with `id`, `format=raw`,
    /// `estimateContentLength=true` and the Subsonic token auth only: no `maxBitRate`, never the password.
    @Test func docClaim_appStreamURLOriginalIsRaw() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        model.play([Self.song("s1"), Self.song("s2")], startAt: 0)
        let items = try #require(engine.setItemsCalls.last?.items)
        #expect(items.count == 2)
        for (_, url) in items {
            let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(comps.host == "192.168.1.2" && comps.path == "/rest/stream")
            let names = Set((comps.queryItems ?? []).map(\.name))
            #expect(names == ["u", "t", "s", "v", "c", "f", "id", "format", "estimateContentLength"], "\(names)")
            #expect(comps.queryItems?.first { $0.name == "format" }?.value == "raw")
            #expect(comps.queryItems?.first { $0.name == "estimateContentLength" }?.value == "true")
            #expect(!url.absoluteString.contains("pw"), "the password is never in a stream URL")
        }
        tearDown(model)
    }

    // MARK: - §3c Failures and failover

    /// FLOWS §3a/§3c: a failed current song stops playback; the playback error triggers the failover check and the
    /// player rebuilds its URLs and seeks back. Playback does NOT resume by itself: the owner presses play.
    @Test func failedSongStaysPausedAfterFailoverUntilPlay() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home, away], username: "admin", password: "pw")
        model.play([Self.song("s1"), Self.song("s2")], startAt: 0)
        let current = try #require(model.player.queue.current?.id)
        model.player.handle(.time(current, 42, duration: 200))
        let playsBefore = engine.playCount

        transport.setDown([home.host!])
        model.player.handle(.failed(current, "The server stopped answering."))
        for _ in 0..<300 where model.session?.activeBase != away { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.session?.activeBase == away)
        #expect(engine.setItemsCalls.last?.items.allSatisfy { $0.1.host == "music.example.com" } == true)
        #expect(engine.seeks.last == 42, "seeks back to where it was")
        #expect(engine.playCount == playsBefore, "no automatic resume after the failover")
        #expect(!model.player.isPlaying)
        #expect(model.player.lastError != nil)

        model.player.toggle()
        #expect(engine.playCount == playsBefore + 1 && model.player.isPlaying, "play resumes on the new address")
        #expect(engine.setItemsCalls.last?.items.first?.1.host == "music.example.com")
        tearDown(model)
    }

    // MARK: - §3d Scrobbling

    /// FLOWS §3d: on start `submission=false` (no time); at 50 % `submission=true` with the start time (ms).
    @Test func docClaim_nowPlayingThenSubmissionWithStartTime() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        model.play([Self.song("s1", duration: 200)], startAt: 0)
        let after = Int64(Date().timeIntervalSince1970 * 1000)
        let entry = try #require(model.player.queue.current?.id)
        await model.player.waitForPendingScrobbles()
        var sent = scrobbleRequests()
        #expect(sent.count == 1)
        let ping = try #require(sent.first?.queryItems)
        #expect(ping.first { $0.name == "submission" }?.value == "false")
        #expect(ping.first { $0.name == "id" }?.value == "s1")
        #expect(!ping.contains { $0.name == "time" })

        model.player.listen(entry, from: 0, to: 99, duration: 200)
        await model.player.waitForPendingScrobbles()
        #expect(scrobbleRequests().count == 1, "not before half")
        model.player.listen(entry, from: 99, to: 150, duration: 200)
        await model.player.waitForPendingScrobbles()
        sent = scrobbleRequests()
        #expect(sent.count == 2, "submitted once")
        let submission = try #require(sent.last?.queryItems)
        #expect(submission.first { $0.name == "submission" }?.value == "true")
        let time = try #require(submission.first { $0.name == "time" }?.value.flatMap(Int64.init))
        #expect(time >= before && time <= after, "the time the song started, in ms")
        tearDown(model)
    }

    /// FLOWS §3d: with no length known (song length 0, no engine duration) the cap alone applies: 240 s.
    @Test func unknownLengthScrobblesAt240s() async throws {
        let scrobbler = FakeScrobbler()
        let player = Player(engine: engine, scrobbler: scrobbler, urls: FakeURLs())
        player.play([Self.song("x", duration: 0)], startAt: 0)
        let entry = try #require(player.queue.current?.id)
        player.listen(entry, from: 0, to: 239)
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls == [.init(songId: "x", submission: false)])
        player.listen(entry, from: 239, to: 240)
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls.last == .init(songId: "x", submission: true))
    }

    /// FLOWS §3d: Count plays off silences both the now-playing ping and the submission, through the whole app.
    @Test func countPlaysOffSendsNeitherPingNorSubmission() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        model.setCountPlays(false)
        #expect(defaults.object(forKey: "magpie.countPlays") as? Bool == false, "stored in UserDefaults")
        model.play([Self.song("s1", duration: 200)], startAt: 0)
        let entry = try #require(model.player.queue.current?.id)
        model.player.listen(entry, from: 0, to: 150, duration: 200)
        await model.player.waitForPendingScrobbles()
        #expect(scrobbleRequests().isEmpty)
        tearDown(model)
    }
}

/// Runs the real `AVQueueEngine` on the simulator with local WAV files (no server).
@MainActor
@Suite(.serialized) struct AVQueueEngineVerifyTests {
    /// The engine's private AVQueuePlayer, read by reflection (the test needs the real queue, not a fake).
    static func queuePlayer(_ engine: AVQueueEngine) throws -> AVQueuePlayer {
        try #require(Mirror(reflecting: engine).children.first { $0.label == "player" }?.value as? AVQueuePlayer)
    }

    static func waitReady(_ player: AVQueuePlayer) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, player.currentItem?.status != .readyToPlay || !(player.currentItem?.duration.seconds.isFinite ?? false) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.currentItem?.status == .readyToPlay)
    }

    /// FLOWS §3c "holds at most 3 items and appends the next one when 20 s or less are left, or straight away when
    /// the length is unknown". Measured: on load the next item is appended at once (the length isn't known yet);
    /// with a known length over 20 s nothing is appended; under 20 s the next is appended. Never more than 2.
    @Test func prefetchesOneItemByTheTwentySecondRule() async throws {
        let long = try AVQueueEngineTests.silentWAV(seconds: 60)
        let short = try AVQueueEngineTests.silentWAV(seconds: 2)
        defer { for u in [long, short] { try? FileManager.default.removeItem(at: u) } }
        let ids = (0..<4).map { _ in UUID() }

        let engine = AVQueueEngine()
        let player = try Self.queuePlayer(engine)
        let longList = [(ids[0], long), (ids[1], long), (ids[2], long), (ids[3], long)]
        engine.setItems(longList, startAt: 0)
        #expect(player.items().count == 2, "length unknown at load: the next is appended at once, no more")

        try await Self.waitReady(player)
        // Same current item with a different next: the enqueued follower is dropped (one that is still next is
        // kept, Task 7) and top-up is re-evaluated.
        engine.setItems([(ids[0], long), (ids[2], long), (ids[3], long)], startAt: 0)
        #expect(player.items().count == 1, "60 s left (> 20 s): nothing appended yet")

        let shortList = [(ids[0], short), (ids[1], long), (ids[2], long)]
        engine.setItems(shortList, startAt: 0)
        try await Self.waitReady(player)
        engine.setItems([(ids[0], short), (ids[2], long)], startAt: 0)
        #expect(player.items().count == 2, "2 s left (<= 20 s): the next is appended")
        #expect(player.items().count <= 2)
    }

    /// FLOWS §3c: headphones / car disconnect (route change, old device unavailable) pauses playback.
    @Test func routeLossPauses() async throws {
        let wav = try AVQueueEngineTests.silentWAV(seconds: 30)
        defer { try? FileManager.default.removeItem(at: wav) }
        let engine = AVQueueEngine()
        let player = try Self.queuePlayer(engine)
        var events: [EngineEvent] = []
        let collector = Task { @MainActor in
            for await e in engine.events { if case .time = e { continue }; events.append(e) }
        }
        defer { collector.cancel() }
        engine.setItems([(UUID(), wav)], startAt: 0)
        engine.play()
        try await AVQueueEngineTests.waitUntil { player.rate > 0 }   // QC: starts once the session is active

        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: session, userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
        ])
        #expect(player.rate > 0, "a new device does not pause")
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: session, userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
        ])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, player.rate != 0 || !events.contains(.playing(false)) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.rate == 0, "the old device went away: paused")
        #expect(events.contains(.playing(false)))
    }

    /// FLOWS §3c: "the player is rebuilt if media services reset": a new AVQueuePlayer on the same entry.
    @Test func mediaServicesResetRebuildsThePlayerOnTheSameEntry() async throws {
        let wav = try AVQueueEngineTests.silentWAV(seconds: 30)
        let next = try AVQueueEngineTests.silentWAV(seconds: 30)
        defer { for u in [wav, next] { try? FileManager.default.removeItem(at: u) } }
        let id = UUID(), nextId = UUID()
        let engine = AVQueueEngine()
        let before = try Self.queuePlayer(engine)
        var events: [EngineEvent] = []
        let collector = Task { @MainActor in
            for await e in engine.events { if case .time = e { continue }; events.append(e) }
        }
        defer { collector.cancel() }
        engine.setItems([(id, wav), (nextId, next)], startAt: 0)
        engine.play()

        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification,
                                        object: AVAudioSession.sharedInstance())
        let rebuildDeadline = Date().addingTimeInterval(5)
        while Date() < rebuildDeadline, try Self.queuePlayer(engine) === before { try await Task.sleep(for: .milliseconds(20)) }
        let after = try Self.queuePlayer(engine)
        #expect(after !== before, "a new AVQueuePlayer")
        #expect((after.currentItem?.asset as? AVURLAsset)?.url == wav, "the same entry is loaded again")
        // QC: the session is activated again off the main thread first, then it plays on.
        let playDeadline = Date().addingTimeInterval(5)
        while Date() < playDeadline, after.rate == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(after.rate > 0, "it was playing, so it plays on")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, events.filter({ $0 == .itemChanged(id) }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!events.contains(.itemChanged(nextId)), "never moves on to another entry")
    }
}

/// FLOWS §3c: Now Playing carries title, artist, album, times and queue index; remote commands are registered.
@MainActor
@Suite(.serialized) struct NowPlayingVerifyTests {
    /// V-fix (V2 O3): the lock screen's like state reads the app's star state (a like from the lock screen or the
    /// phone flips it at once), not the `starred` flag the song was loaded with.
    @Test func likeStateFollowsTheAppsStarState() async throws {
        let stars = StarState()
        let player = Player(engine: FakeEngine(), scrobbler: FakeScrobbler(), urls: FakeURLs())
        let bridge = NowPlayingBridge(player: player, artworkURL: { _ in nil }, onLike: { _ in },
                                      isLiked: { stars.overrides[$0.id] ?? $0.starred })
        defer { bridge.invalidate() }
        let like = MPRemoteCommandCenter.shared().likeCommand
        player.play([Song(id: "1", title: "Song One", artist: "Artist", album: "Album", duration: 180, libraryId: 1)], startAt: 0)
        let center = MPNowPlayingInfoCenter.default()
        for _ in 0..<250 where center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String != "Song One" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!like.isActive)
        stars.overrides["1"] = true
        for _ in 0..<250 where !like.isActive { try await Task.sleep(for: .milliseconds(20)) }
        #expect(like.isActive, "a star made in the app shows on the lock screen without a song change")
        stars.overrides["1"] = false
        for _ in 0..<250 where like.isActive { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!like.isActive)
    }

    @Test func nowPlayingInfoAndRemoteCommands() async throws {
        let engine = FakeEngine()
        let player = Player(engine: engine, scrobbler: FakeScrobbler(), urls: FakeURLs())
        let bridge = NowPlayingBridge(player: player, artworkURL: { _ in nil }, onLike: { _ in })
        defer { bridge.invalidate() }
        player.play([Song(id: "1", title: "Song One", artist: "Artist", album: "Album", duration: 180, libraryId: 1),
                     Song(id: "2", title: "Two", artist: "Artist", album: "Album", duration: 100, libraryId: 1)], startAt: 0)
        let center = MPNowPlayingInfoCenter.default()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String != "Song One" {
            try await Task.sleep(for: .milliseconds(20))
        }
        let info = try #require(center.nowPlayingInfo)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Song One")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Artist")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Album")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval == 180)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 0)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 0)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 2)

        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
                        commands.nextTrackCommand, commands.previousTrackCommand, commands.changePlaybackPositionCommand,
                        commands.changeShuffleModeCommand, commands.changeRepeatModeCommand, commands.likeCommand] {
            #expect(command.isEnabled)
        }
    }
}

/// Stands in for `AppModel.starOverrides` (observable, so the bridge sees changes).
@MainActor @Observable private final class StarState {
    var overrides: [String: Bool] = [:]
}
