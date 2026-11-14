import Foundation
import MagpieCore
import Testing
@testable import Playback

/// Round 27 P (owner item 11, 2026-11-14): converted streams that don't skip. A dropped connection picks up where it
/// was on the same quality (D278), the position counts the offset a reload started at (D278), seeks reload part-way
/// where the server can start a conversion there (D281), and the next song's stream opens only near the end (D279).
@MainActor
@Suite struct ConvertedStreamTests {
    // MARK: - Fakes

    /// Records what the player asks of its engine, and answers the cause of each failure as the test sets it.
    @MainActor final class RetryEngine: PlaybackEngine {
        let events: AsyncStream<EngineEvent>
        private(set) var setItemsCalls: [[(UUID, URL)]] = []
        private(set) var seeks: [TimeInterval] = []
        private(set) var playCount = 0
        private(set) var pauseCount = 0
        private(set) var lengths: [UUID: TimeInterval] = [:]
        var causes: [UUID: PlaybackFailure.Cause] = [:]
        init() { events = AsyncStream { $0.finish() } }
        func setItems(_ urls: [(UUID, URL)], startAt: Int) { setItemsCalls.append(urls) }
        func play() { playCount += 1 }
        func pause() { pauseCount += 1 }
        func seek(to t: TimeInterval) { seeks.append(t) }
        func next() {}
        func setLengths(_ lengths: [UUID: TimeInterval]) { self.lengths = lengths }
        func failureCause(for id: UUID) -> PlaybackFailure.Cause { causes[id] ?? .unknown }
        /// The URL the current entry was last sent on.
        var currentURL: URL? { setItemsCalls.last?.first?.1 }
    }

    @MainActor final class StreamURLs: StreamURLProvider {
        var format = "aac"
        var local: Set<String> = []
        func streamURL(for song: Song) -> URL {
            if local.contains(song.id) { return URL(filePath: "/tmp/magpie-r27/\(song.id).flac") }
            return URL(string: "https://music.example/rest/stream?id=\(song.id)&maxBitRate=160&format=\(format)")!
        }
        func originalURL(for song: Song) -> URL? {
            local.contains(song.id) ? nil : URL(string: "https://music.example/rest/stream?id=\(song.id)&format=raw")!
        }
        func isOriginal(_ url: URL) -> Bool { url.query?.contains("format=raw") == true }
    }

    /// A sleep the test lets go of: each call waits until `release()`.
    final class ManualSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var _asked: [Duration] = []
        var asked: [Duration] { lock.withLock { _asked } }
        var pending: Int { lock.withLock { waiting.count } }
        func sleep(_ d: Duration) async {
            await withCheckedContinuation { c in lock.withLock { _asked.append(d); waiting.append(c) } }
        }
        func release() { lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }?.resume() }
    }

    final class Plays: Scrobbler, @unchecked Sendable {
        private let lock = NSLock()
        private var _submitted: [String] = []
        var submitted: [String] { lock.withLock { _submitted } }
        func scrobble(_ song: Song, submission: Bool, at: Date?) async throws {
            if submission { lock.withLock { _submitted.append(song.id) } }
        }
    }

    static func song(_ id: String, duration: TimeInterval = 200) -> Song {
        Song(id: id, title: id, artist: "A", album: "B", duration: duration)
    }

    struct Rig {
        let player: Player
        let engine: RetryEngine
        let urls: StreamURLs
        let sleeper: ManualSleeper
        let plays: Plays
    }

    func rig(partWay: Bool = true, online: Bool = true, songs: [String] = ["1", "2", "3"]) -> Rig {
        let engine = RetryEngine(), urls = StreamURLs(), sleeper = ManualSleeper(), plays = Plays()
        let player = Player(engine: engine, scrobbler: plays, urls: urls, sleep: { await sleeper.sleep($0) })
        player.startsConversionsPartWay = { partWay }
        player.canReachServer = { online }
        player.play(songs.map { Self.song($0) }, startAt: 0)
        return Rig(player: player, engine: engine, urls: urls, sleeper: sleeper, plays: plays)
    }

    func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
    }

    func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// The current entry plays to `t` and then its connection drops.
    func dropConnection(_ r: Rig, at t: TimeInterval) {
        let id = r.player.queue.current!.id
        r.player.listen(id, from: max(0, r.player.position - StreamOffsetTesting.offset(r)), to: t)
        r.engine.causes[id] = .network
        r.player.handle(.failed(id, "The network connection was lost."))
    }

    enum StreamOffsetTesting {
        @MainActor static func offset(_ r: Rig) -> TimeInterval { TimeInterval(StreamOffset.seconds(in: r.player.currentURL)) }
    }

    // MARK: - D278: a dropped converted stream

    @Test func network_retriesSameQualityWithTimeOffset() async throws {
        let r = rig()
        let id = r.player.queue.current!.id
        dropConnection(r, at: 95.5)
        #expect(r.player.lastError == nil, "no error while it picks up")
        #expect(r.player.reconnectingSongId == "1")
        await settle { r.sleeper.pending == 1 }
        #expect(r.sleeper.asked == [.seconds(1)])
        let sends = r.engine.setItemsCalls.count
        r.sleeper.release()
        await settle { r.engine.setItemsCalls.count > sends }
        let q = query(r.engine.currentURL)
        #expect(r.engine.currentURL.map { $0.absoluteString.hasPrefix("https://music.example/rest/stream") } == true)
        #expect(q["timeOffset"] == "95" && q["format"] == "aac" && q["maxBitRate"] == "160", "same quality, from 95 s")
        #expect(r.engine.setItemsCalls.last?.first?.0 == id, "the same entry")
        #expect(r.player.position == 95)
        #expect(r.engine.playCount >= 2, "it plays again")
        #expect(r.player.isPlaying && r.player.lastFallbackSongId == nil)
    }

    @Test func network_retryHintClearsOnTick() async throws {
        let r = rig()
        let id = r.player.queue.current!.id
        dropConnection(r, at: 40)
        await settle { r.sleeper.pending == 1 }
        r.sleeper.release()
        await settle { query(r.engine.currentURL)["timeOffset"] == "40" }
        #expect(r.player.reconnectingSongId == "1", "still picking up until sound arrives")
        r.player.handle(.time(id, 0.5, duration: nil))
        #expect(r.player.reconnectingSongId == nil)
        #expect(r.player.position == 40.5)
    }

    @Test func network_withoutTranscodeOffsetSeeks() async throws {
        let r = rig(partWay: false)
        let before = r.engine.currentURL
        dropConnection(r, at: 70)
        await settle { r.sleeper.pending == 1 }
        r.sleeper.release()
        await settle { r.engine.seeks.contains(70) }
        #expect(r.engine.currentURL == before, "the same stream from the start")
        #expect(query(r.engine.currentURL)["timeOffset"] == nil)
        #expect(r.engine.seeks.last == 70, "then a best-effort seek")
        #expect(r.player.position == 70)
    }

    @Test func network_twoRetriesThenStops() async throws {
        let r = rig()
        dropConnection(r, at: 30)
        await settle { r.sleeper.pending == 1 }
        r.sleeper.release()
        await settle { query(r.engine.currentURL)["timeOffset"] == "30" }
        dropConnection(r, at: 5)   // 35 s in
        await settle { r.sleeper.pending == 1 }
        #expect(r.sleeper.asked == [.seconds(1), .seconds(3)])
        r.sleeper.release()
        await settle { query(r.engine.currentURL)["timeOffset"] == "35" }
        dropConnection(r, at: 2)
        await settle { false }
        #expect(r.sleeper.asked.count == 2, "no third retry")
        #expect(r.player.lastError == "The network connection was lost.")
        #expect(!r.player.isPlaying && r.player.reconnectingSongId == nil)
    }

    @Test func network_neverSwitchesToOriginal() async throws {
        let r = rig()
        for _ in 0..<3 {
            dropConnection(r, at: 1.5)
            await settle { r.sleeper.pending == 1 }
            r.sleeper.release()
            await settle { r.sleeper.pending == 0 }
        }
        #expect(!r.engine.setItemsCalls.flatMap { $0 }.contains { $0.1.query?.contains("format=raw") == true })
        #expect(r.player.lastFallbackSongId == nil)
    }

    @Test func network_offlineStopsWithoutRetrying() async throws {
        let r = rig(online: false)
        dropConnection(r, at: 50)
        await settle { false }
        #expect(r.sleeper.asked.isEmpty)
        #expect(r.player.lastError != nil && !r.player.isPlaying && r.player.reconnectingSongId == nil)
    }

    @Test func network_songChangedDuringTheWaitIsLeftAlone() async throws {
        let r = rig()
        dropConnection(r, at: 50)
        await settle { r.sleeper.pending == 1 }
        r.player.next()
        #expect(r.player.queue.current?.song.id == "2" && r.player.reconnectingSongId == nil)
        let sends = r.engine.setItemsCalls.count
        r.sleeper.release()
        await settle { false }
        #expect(r.engine.setItemsCalls.count == sends, "the old song isn't reloaded")
        #expect(query(r.engine.currentURL)["id"] == "2" && query(r.engine.currentURL)["timeOffset"] == nil)
    }

    @Test func network_playDuringTheWaitPicksUpAtOnce() async throws {
        let r = rig()
        dropConnection(r, at: 50)
        await settle { r.sleeper.pending == 1 }
        r.player.toggle()   // pause
        r.player.toggle()   // play: picks up now, from where it was
        #expect(query(r.engine.currentURL)["timeOffset"] == "50" && r.player.position == 50)
        r.sleeper.release()
        let sends = r.engine.setItemsCalls.count
        await settle { false }
        #expect(r.engine.setItemsCalls.count == sends, "the wait that ends later does nothing")
    }

    @Test func network_onAnOriginalStreamIsTodays() async throws {
        let r = rig()
        r.urls.format = "raw"
        r.player.play([Self.song("9")], startAt: 0)
        dropConnection(r, at: 20)
        await settle { false }
        #expect(r.sleeper.asked.isEmpty && r.player.lastError != nil, "only converted streams pick up")
    }

    @Test func conversion_stillFallsBackToOriginalOnce() async throws {
        let r = rig()
        let id = r.player.queue.current!.id
        r.player.handle(.failed(id, "couldn't convert"))   // before a second played, unknown cause
        #expect(query(r.engine.currentURL)["format"] == "raw" && r.player.lastFallbackSongId == "1")
        r.player.handle(.failed(id, "still no"))
        #expect(r.player.lastError == "still no", "once")

        let s = rig()
        let sid = s.player.queue.current!.id
        s.player.listen(sid, from: 0, to: 60)
        s.engine.causes[sid] = .serverError
        s.player.handle(.failed(sid, "HTTP 500"))
        #expect(query(s.engine.currentURL)["format"] == "raw", "a server error mid-song too")
        #expect(s.sleeper.asked.isEmpty)
    }

    @Test func undecodableConvertedStream_keepsTodaysFallback() async throws {
        let r = rig()
        let id = r.player.queue.current!.id
        r.player.listen(id, from: 0, to: 30)
        r.engine.causes[id] = .undecodable
        r.player.handle(.failed(id, "bad bytes", undecodable: true))
        #expect(query(r.engine.currentURL)["format"] == "raw")
    }

    // MARK: - D278: position and listening with an offset

    @Test func offset_positionAddsOffset() async throws {
        let r = rig()
        let id = r.player.queue.current!.id
        dropConnection(r, at: 120)
        await settle { r.sleeper.pending == 1 }
        r.sleeper.release()
        await settle { query(r.engine.currentURL)["timeOffset"] == "120" }
        r.player.handle(.time(id, 2, duration: 80))
        #expect(r.player.position == 122)
        #expect(r.player.duration == 200, "the API's length stays (D45)")
    }

    @Test func offset_noListeningCreditForTheJump() async throws {
        let r = rig()
        let id = r.player.queue.current!.id
        dropConnection(r, at: 60)   // 60 s heard
        await settle { r.sleeper.pending == 1 }
        r.sleeper.release()
        await settle { query(r.engine.currentURL)["timeOffset"] == "60" }
        r.player.listen(id, from: 0, to: 39.5)   // 99.5 s heard in all
        await r.player.waitForPendingScrobbles()
        #expect(r.plays.submitted.isEmpty, "the jump from 0 to 60 isn't listening")
        r.player.listen(id, from: 39.5, to: 40)
        await r.player.waitForPendingScrobbles()
        #expect(r.plays.submitted == ["1"])
    }

    // MARK: - D281: seeks on a converted stream

    @Test func seek_convertedReloadsWithTimeOffset() async throws {
        let r = rig()
        r.player.toggle()   // paused stays paused
        let plays = r.engine.playCount
        r.player.seek(42.7)
        #expect(query(r.engine.currentURL)["timeOffset"] == "42")
        #expect(r.engine.seeks.isEmpty, "no approximate seek")
        #expect(r.player.position == 42 && !r.player.isPlaying && r.engine.playCount == plays)
        let id = r.player.queue.current!.id
        r.player.handle(.time(id, 1, duration: nil))
        #expect(r.player.position == 43)

        r.player.seek(10)
        #expect(query(r.engine.currentURL)["timeOffset"] == "10", "a seek back reloads too")
    }

    @Test func seek_withoutTranscodeOffsetIsTodays() async throws {
        let r = rig(partWay: false)
        let before = r.engine.setItemsCalls.count
        r.player.seek(42.7)
        #expect(r.engine.seeks == [42.7] && r.engine.setItemsCalls.count == before)
    }

    @Test func seek_fileOrOriginalIsTodays() async throws {
        let r = rig()
        r.urls.local = ["5"]
        r.player.play([Self.song("5")], startAt: 0)
        let before = r.engine.setItemsCalls.count
        r.player.seek(30)
        #expect(r.engine.seeks == [30] && r.engine.setItemsCalls.count == before)
    }

    @Test func restartFromTop_usesTimeOffsetZero() async throws {
        let r = rig()
        let id = r.player.queue.current!.id
        r.player.listen(id, from: 0, to: 50)
        r.player.previous()
        #expect(query(r.engine.currentURL)["timeOffset"] == "0")
        #expect(r.player.position == 0 && r.player.queue.current?.id == id)
    }

    // MARK: - D279: lengths for the engine

    @Test func player_sendsApiLengths() {
        let r = rig(songs: ["1", "2"])
        r.player.addToEnd([Self.song("x", duration: 0)])
        let current = r.player.queue.current!.id
        #expect(r.engine.lengths[current] == 200)
        #expect(r.engine.lengths.count == 2, "an unknown length isn't sent")
    }

    @Test func topUp_usesApiLengthForChunkedStream() {
        // A chunked transcode has no length of its own: the API's tells when 20 s are left.
        #expect(AVQueueEngine.remaining(itemDuration: .indefinite, apiLength: 200, offset: 0, currentTime: 10) == 190)
        #expect(AVQueueEngine.remaining(itemDuration: .nan, apiLength: 200, offset: 0, currentTime: 185) == 15)
        #expect(AVQueueEngine.remaining(itemDuration: .indefinite, apiLength: 200, offset: 120, currentTime: 70) == 10,
                "a stream that started part-way")
    }

    @Test func topUp_ownLengthWinsWhenKnown() {
        #expect(AVQueueEngine.remaining(itemDuration: 180, apiLength: 200, offset: 0, currentTime: 170) == 10)
    }

    @Test func topUp_unknownLengthStillAtOnce() {
        #expect(AVQueueEngine.remaining(itemDuration: .indefinite, apiLength: nil, offset: 0, currentTime: 3) == 0)
        #expect(AVQueueEngine.remaining(itemDuration: .indefinite, apiLength: .nan, offset: 0, currentTime: 3) == 0)
        #expect(AVQueueEngine.remaining(itemDuration: .indefinite, apiLength: 0, offset: 0, currentTime: 3) == 0)
        #expect(AVQueueEngine.remaining(itemDuration: .indefinite, apiLength: 200, offset: 0, currentTime: .nan) == 200,
                "a time that isn't a number counts as the start")
    }
}

private extension TimeInterval {
    static let indefinite = TimeInterval.nan
}

extension Player {
    /// The engine plays entry `id` on from `a` to `b` seconds of its own clock: a tick every half second.
    func listen(_ id: UUID, from a: TimeInterval, to b: TimeInterval) {
        var t = a + 0.5
        while t <= b + 0.001 { handle(.time(id, t, duration: nil)); t += 0.5 }
    }
}
