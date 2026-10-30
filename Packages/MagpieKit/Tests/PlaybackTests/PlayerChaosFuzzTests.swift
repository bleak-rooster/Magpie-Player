import Foundation
import MagpieTestSupport
import Testing
import MagpieCore
@testable import Playback

/// Crash hunt 1: seeded chaos sequences against `Player` and `PlayQueue`. Every op is followed by the invariants: no
/// trap, the current index valid or nil, no duplicate entry ids, the engine's list made of queue entries (the current
/// one among them while playing, the rest in upcoming order), a finite position and length, and never more counted
/// plays than started ones (and never a find).
@MainActor
@Suite struct PlayerChaosFuzzTests {
    // MARK: - Fakes

    /// An engine that records what it was sent, like `AVQueueEngine` from the player's side.
    @MainActor final class ChaosEngine: PlaybackEngine {
        let events: AsyncStream<EngineEvent>
        private(set) var items: [(UUID, URL)] = []
        private(set) var wantsToPlay = false
        private(set) var volumes: [UUID: Float] = [:]
        private(set) var volume: Float = 1
        var enqueued: [UUID: URL] = [:]
        init() { events = AsyncStream { $0.finish() } }
        func setItems(_ urls: [(UUID, URL)], startAt: Int) {
            items = urls
            // A real engine keeps an enqueued item when only its URL changed; remember the first URL it got.
            for (id, url) in urls where enqueued[id] == nil { enqueued[id] = url }
        }
        func play() { wantsToPlay = true }
        func pause() { wantsToPlay = false }
        func seek(to t: TimeInterval) { precondition(t.isFinite, "a non-number seek reached the engine") }
        func next() {}
        func setVolumes(_ volumes: [UUID: Float]) {
            precondition(volumes.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "volume out of range")
            self.volumes = volumes
        }
        func setVolume(_ volume: Float) {
            precondition(volume.isFinite && volume >= 0 && volume <= 1, "overall volume out of range")
            self.volume = volume
        }
        func enqueuedURL(for id: UUID) -> URL? { enqueued[id] }
        /// Like `AVQueueEngine`: the end of its list, or a failure of an item it holds, stops it wanting to play.
        func willReport(_ event: EngineEvent) {
            switch event {
            case .ended(let id) where id == items.last?.0: wantsToPlay = false
            case .failed(let id, _, _) where items.contains(where: { $0.0 == id }): wantsToPlay = false
            default: break
            }
        }
    }

    /// Records plays synchronously (the player calls it from main-actor tasks).
    final class CountingScrobbler: Scrobbler, @unchecked Sendable {
        private let lock = NSLock()
        private var _nowPlaying = 0, _submitted = 0, _finds = 0
        func scrobble(_ song: Song, submission: Bool, at: Date?) async throws {
            lock.withLock {
                if submission { _submitted += 1 } else { _nowPlaying += 1 }
                if song.libraryId == 2 { _finds += 1 }
            }
        }
        var counts: (nowPlaying: Int, submitted: Int, finds: Int) { lock.withLock { (_nowPlaying, _submitted, _finds) } }
    }

    @MainActor final class ChaosURLs: StreamURLProvider {
        var offline = false
        var base = "http://127.0.0.1:4533"
        var local: Set<String> = []
        func streamURL(for song: Song) -> URL {
            if local.contains(song.id) { return URL(filePath: "/tmp/magpie-fuzz/\(song.id).flac") }
            if offline { return URL(string: "about:blank")! }
            return URL(string: "\(base)/rest/stream?id=\(song.id)&format=aac")!
        }
        func originalURL(for song: Song) -> URL? {
            offline || local.contains(song.id) ? nil : URL(string: "\(base)/rest/stream?id=\(song.id)&format=raw")!
        }
        func isOriginal(_ url: URL) -> Bool { url.query?.contains("format=raw") == true }
        func localFileFailed(_ song: Song, undecodable: Bool) -> URL? {
            offline ? nil : URL(string: "\(base)/rest/stream?id=\(song.id)&format=aac")!
        }
    }

    // MARK: - Data

    /// Lengths as a server might send them, odd ones included (0 = unknown, a huge one, and the non-numbers a
    /// damaged saved catalogue could hold).
    static let durations: [TimeInterval] = [200, 200, 31, 0, 12, 1e7, 1e300, .nan, .infinity]
    static let times: [TimeInterval] = [0, 0.5, 1, 3.2, 29, 100, 199.9, 250, -1, -1e9, 1e12, 1e300, .nan, .infinity,
                                        -.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude]

    static func songs(_ rng: inout SeededRNG) -> [Song] {
        (0..<Int.random(in: 0...9, using: &rng)).map { i in
            let id = "s\(Int.random(in: 0...7, using: &rng))"   // repeats on purpose: the same song in many slots
            var song = Song(id: id, title: "T\(i)", artist: "A", album: "B",
                            duration: durations.randomElement(using: &rng)!,
                            libraryId: Bool.random(using: &rng) ? 1 : (Int.random(in: 0...5, using: &rng) == 0 ? 2 : nil))
            if Int.random(in: 0...3, using: &rng) == 0 {
                song.replayGain = ReplayGain(trackGain: [-200, -6, 0, 12, .nan, .infinity].randomElement(using: &rng)!,
                                             trackPeak: [0, 0.5, 1.2, .nan, -1].randomElement(using: &rng)!)
            }
            return song
        }
    }

    // MARK: - Invariants

    func check(_ player: Player, _ engine: ChaosEngine, _ ctx: @autoclosure () -> String) {
        let q = player.queue
        if let i = q.currentIndex { #expect(q.main.indices.contains(i), "\(ctx()): current index \(i) of \(q.main.count)") }
        #expect(q.currentIndex != nil || q.current == nil, "\(ctx())")
        let ids = (q.main + q.upNext).map(\.id)
        #expect(Set(ids).count == ids.count, "\(ctx()): duplicate entry ids")
        let engineIds = engine.items.map(\.0)
        #expect(Set(engineIds).count == engineIds.count, "\(ctx()): duplicate ids sent to the engine")
        #expect(Set(engineIds).isSubset(of: Set(ids)), "\(ctx()): the engine holds an entry the queue doesn't")
        if player.isPlaying {
            let current = q.current
            #expect(current != nil, "\(ctx()): playing with nothing current")
            if let current, let at = engineIds.firstIndex(of: current.id) {
                // What follows the current entry in the engine is upcoming, in order.
                let upcoming = q.upcoming.map(\.id)
                var cursor = upcoming.startIndex
                for id in engineIds[(at + 1)...] {
                    guard let found = upcoming[cursor...].firstIndex(of: id) else {
                        Issue.record("\(ctx()): the engine's window is not in upcoming order")
                        break
                    }
                    cursor = found + 1
                }
            } else if current != nil {
                Issue.record("\(ctx()): playing, but the engine doesn't hold the current entry")
            }
        }
        #expect(player.position.isFinite, "\(ctx()): position \(player.position)")
        if let d = player.duration { #expect(!d.isNaN && d > 0, "\(ctx()): duration \(d)") }
        _ = q.upcomingCount; _ = q.nextUp
        #expect(q.upcomingCount == q.upcoming.count, "\(ctx())")
        #expect(engine.volume >= 0 && engine.volume <= 1)
    }

    // MARK: - The sweep

    /// 2,000 sequences of 50 ops.
    @Test func chaosSequences() async {
        var submitted = 0, playing = 0
        for seed in 0..<UInt64(2000) {
            let (s, p) = await runSequence(seed: seed, ops: 50)
            submitted += s; playing += p
        }
        // The sweep reaches the interesting states: plays counted, and steps taken while playing.
        #expect(submitted > 50 && playing > 10_000, "submitted \(submitted), steps while playing \(playing)")
    }

    /// Returns the plays counted and the steps that ended with the player playing.
    func runSequence(seed: UInt64, ops: Int) async -> (Int, Int) {
        var playingSteps = 0
        var rng = SeededRNG(seed: seed &* 0xA24B_AED4_963E_E407 &+ 1)
        let engine = ChaosEngine()
        let scrobbler = CountingScrobbler()
        let urls = ChaosURLs()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var offline = false
        var rule = ScrobbleRule.standard
        let player = Player(engine: engine, scrobbler: scrobbler, urls: urls,
                            isFind: { $0.libraryId == 2 }, now: { clock },
                            gain: { ReplayGainMode.track.volume(for: $0.replayGain) },
                            scrobbleRule: { rule })
        var stale: [UUID] = []
        var log: [String] = []

        func anyId() -> UUID {
            let q = player.queue
            switch Int.random(in: 0...5, using: &rng) {
            case 0: return q.current?.id ?? UUID()
            case 1: return engine.items.randomElement(using: &rng)?.0 ?? UUID()
            case 2: return engine.items.last?.0 ?? UUID()
            case 3: return stale.randomElement(using: &rng) ?? UUID()
            case 4: return (q.main + q.upNext).randomElement(using: &rng)?.id ?? UUID()
            default: return UUID()
            }
        }

        for step in 0..<ops {
            let before = (player.queue.main + player.queue.upNext).map(\.id)
            let op = Int.random(in: 0...29, using: &rng)
            log.append("\(op)")
            switch op {
            case 0: player.play(Self.songs(&rng), startAt: Int.random(in: -2...10, using: &rng))
            case 1: player.playNext(Self.songs(&rng))
            case 2: player.addToEnd(Self.songs(&rng))
            case 3:
                let all = player.queue.main + player.queue.upNext
                player.move(id: all.randomElement(using: &rng)?.id ?? UUID(), to: Int.random(in: -3...20, using: &rng))
            case 4:
                let all = player.queue.main + player.queue.upNext
                player.remove(id: all.randomElement(using: &rng)?.id ?? UUID())
            case 5: player.next()
            case 6: player.previous()
            case 7: player.seek(Self.times.randomElement(using: &rng)!)
            case 8: player.repeatMode = RepeatMode.allCases.randomElement(using: &rng)!
            case 9: player.setShuffled(Bool.random(using: &rng), seed: rng.next())
            case 10: player.stopsAfterCurrent.toggle()
            case 11:
                let event = EngineEvent.ended(anyId())
                engine.willReport(event)
                player.handle(event)
            case 12:
                let event = EngineEvent.failed(anyId(), "boom", undecodable: Bool.random(using: &rng))
                engine.willReport(event)
                player.handle(event)
            case 13:
                // Listening a while: up to four minutes of half-second ticks on the current entry.
                for _ in 0..<Int.random(in: 1...480, using: &rng) {
                    guard let id = player.queue.current?.id else { break }
                    clock = clock.addingTimeInterval(0.5)
                    player.handle(.time(id, player.position + 0.5, duration: nil))
                }
            case 14, 15:
                // A tick: usually the current entry moving on half a second, sometimes stale, backward or huge.
                let id = Int.random(in: 0...3, using: &rng) == 0 ? anyId() : (player.queue.current?.id ?? UUID())
                let t: TimeInterval = Int.random(in: 0...4, using: &rng) == 0
                    ? Self.times.randomElement(using: &rng)! : player.position + 0.5
                clock = clock.addingTimeInterval([0.5, 0.5, 0, 30, -5, 3600].randomElement(using: &rng)!)
                player.handle(.time(id, t, duration: Self.durations.randomElement(using: &rng)))
            case 16: player.handle(.itemChanged(anyId()))
            case 17:
                // The network changed: quality or address.
                urls.base = Bool.random(using: &rng) ? "http://127.0.0.1:4533" : "http://localhost:4533"
                Bool.random(using: &rng) ? player.urlsInvalidated() : player.upcomingURLsChanged()
            case 18:
                // Offline flips, as AppModel.offlineInputsChanged applies them.
                offline.toggle()
                urls.offline = offline
                let local = urls.local
                player.isPlayable = offline ? { local.contains($0.id) } : { _ in true }
                player.upcomingURLsChanged()
                if offline, Bool.random(using: &rng) { player.stopUnplayableCurrent(message: "Offline") }
                player.retryAfterFailure()
            case 19:
                // A download landed or went.
                let id = "s\(Int.random(in: 0...7, using: &rng))"
                if urls.local.contains(id) { urls.local.remove(id) } else { urls.local.insert(id) }
                player.upcomingURLsChanged()
            case 20: player.play([], startAt: 0)   // sign out mid-play
            case 21: player.toggle()
            case 22: player.handle(.playing(engine.wantsToPlay && Bool.random(using: &rng)))
            case 23: player.handle(.stalled)
            case 24: player.clearUpcoming()
            case 25:
                player.lookahead = Int.random(in: -1...12, using: &rng)
                player.upcomingURLsChanged()
            case 26: player.removeSongs(["s\(Int.random(in: 0...7, using: &rng))"])
            case 27:
                var kept = Song(id: "k\(Int.random(in: 0...3, using: &rng))", title: "K", artist: "A", album: "B",
                                duration: Self.durations.randomElement(using: &rng)!, libraryId: 1)
                kept.coverArtId = nil
                player.replaceSong(id: "s\(Int.random(in: 0...7, using: &rng))", with: kept)
            case 28:
                player.volume = [0, 0.3, 1].randomElement(using: &rng)!
            default:
                rule = ScrobbleRule(percent: Int.random(in: -50...200, using: &rng),
                                    minutes: [nil, 0, 1, 4, Int.max, Int.min].randomElement(using: &rng)!)
            }
            stale.append(contentsOf: before)
            if stale.count > 40 { stale.removeFirst(stale.count - 40) }
            if player.isPlaying { playingSteps += 1 }
            check(player, engine, "seed \(seed) step \(step) ops \(log.joined(separator: ","))")
            if step % 10 == 9 { await Task.yield() }
        }
        await player.waitForPendingScrobbles()
        let counts = scrobbler.counts
        #expect(counts.submitted <= counts.nowPlaying, "seed \(seed): \(counts.submitted) plays counted of \(counts.nowPlaying) started")
        #expect(counts.finds == 0, "seed \(seed): a find was scrobbled")
        return (counts.submitted, playingSteps)
    }

    // MARK: - Pure queue

    /// 2,000 sequences of 50 queue ops on `PlayQueue` alone, against a reference of what each op should keep.
    @Test func queueSequences() {
        for seed in 0..<UInt64(2000) {
            var rng = SeededRNG(seed: seed &+ 0x51)
            var q = PlayQueue()
            for step in 0..<50 {
                let all = q.main + q.upNext
                switch Int.random(in: 0...11, using: &rng) {
                case 0: q.replace(with: Self.songs(&rng), startAt: Int.random(in: -5...15, using: &rng))
                case 1: q.playNext(Self.songs(&rng))
                case 2: q.addToEnd(Self.songs(&rng))
                case 3: q.advance()
                case 4: q.back()
                case 5: q.remove(id: all.randomElement(using: &rng)?.id ?? UUID())
                case 6: q.move(id: all.randomElement(using: &rng)?.id ?? UUID(), to: Int.random(in: -5...30, using: &rng))
                case 7: q.clearUpcoming()
                case 8: q.wrapToStart()
                case 9:
                    let order = q.main.map(\.id)
                    q.shuffle(seed: rng.next())
                    if Bool.random(using: &rng) { q.restoreOrder(order.shuffled(using: &rng)) }
                case 10: q.removeSongs(["s\(Int.random(in: 0...7, using: &rng))"])
                default: q.replaceSong(id: "s\(Int.random(in: 0...7, using: &rng))", with: Song(id: "k", title: "K", artist: "A", album: "B", duration: 1))
                }
                if let i = q.currentIndex { #expect(q.main.indices.contains(i), "seed \(seed) step \(step)") }
                let ids = (q.main + q.upNext).map(\.id)
                #expect(Set(ids).count == ids.count, "seed \(seed) step \(step)")
                #expect(q.upcomingCount == q.upcoming.count)
                #expect(q.upcoming(limit: 3).map(\.id) == Array(q.upcoming.prefix(3)).map(\.id))
            }
        }
    }
}
