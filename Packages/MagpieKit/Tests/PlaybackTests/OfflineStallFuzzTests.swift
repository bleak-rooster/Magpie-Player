import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Playback

/// Round 28 crash hunt (R28X): 600 seeded sequences of stalls, ticks, pauses, seeks, skips, failures and rapid
/// online/offline flips (automatic and manual) against the offline stall grace (D349), with the grace's sleeps held and
/// let go by the test, so every run is the same. After every step: the chaos suite's invariants; a held song plays
/// nothing and holds nothing; offline nothing plays from a stream except the one an automatic switch let play on; and a
/// silent stream offline is always being waited out (`isStalled`), never left silent for good. After the last step every
/// grace is let go: no stall is left showing.
@MainActor
@Suite struct OfflineStallFuzzTests {
    /// The grace's sleep, on the main actor, so a released one runs at the test's next yield (FIFO), deterministically.
    @MainActor final class HeldSleeps {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var count: Int { waiting.count }
        func sleep() async { await withCheckedContinuation { waiting.append($0) } }
        func releaseFirst() {
            guard !waiting.isEmpty else { return }
            waiting.removeFirst().resume()
        }
        func releaseAll() {
            let all = waiting
            waiting = []
            all.forEach { $0.resume() }
        }
    }

    @Test func offline_randomStallsAndFlipsNeverStickOrPlayStreams() async {
        var stalledSteps = 0
        for seed in 0..<UInt64(600) {
            stalledSteps += await run(seed: seed, ops: 50)
        }
        #expect(stalledSteps > 200, "the sweep spends time stalled offline: \(stalledSteps) steps")
    }

    /// Lets the released sleeps' tasks run (each is one main-actor job, queued before these yields).
    func drain() async { for _ in 0..<8 { await Task.yield() } }

    /// Returns the steps that ended stalled offline.
    func run(seed: UInt64, ops: Int) async -> Int {
        var rng = SeededRNG(seed: seed &* 0xD1B5_4A32_D192_ED03 &+ 7)
        let engine = PlayerChaosFuzzTests.ChaosEngine()
        let urls = PlayerChaosFuzzTests.ChaosURLs()
        let phone = OfflineTransitionTests.Phone(Set((0..<6).map { "s\($0)" }.filter { _ in Int.random(in: 0...2, using: &rng) == 0 }))
        urls.local = phone.local
        let sleeps = HeldSleeps()
        let player = Player(engine: engine, scrobbler: PlayerChaosFuzzTests.CountingScrobbler(), urls: urls,
                            sleep: { @MainActor _ in await sleeps.sleep() })
        player.canReachServer = { [urls] in !urls.offline }
        var offline = false
        /// The entry an automatic switch found streaming: it may play on until it fails (D330).
        var playsOn: UUID?
        /// The entry whose stream stalled with no sound since (the test's own record).
        var silent: UUID?
        var log: [String] = []
        var stalledOffline = 0

        func songs() -> [Song] {
            (0..<Int.random(in: 1...6, using: &rng)).map { _ in
                let id = "s\(Int.random(in: 0...5, using: &rng))"
                return Song(id: id, title: id, artist: "A", album: "B", duration: 200)
            }
        }
        func report(_ event: EngineEvent) {
            engine.willReport(event)
            player.handle(event)
        }
        func currentURL() -> URL? { player.queue.current.flatMap { c in engine.items.first { $0.0 == c.id }?.1 } }
        func switchTo(offline now: Bool, manual: Bool) {
            if now {
                if !offline, !manual, let c = player.queue.current, currentURL()?.isFileURL == false, player.isPlaying {
                    playsOn = c.id
                }
                if manual { playsOn = nil }
                offline = true
                urls.offline = true
                player.isPlayable = { phone.local.contains($0.id) }
                player.upcomingURLsChanged()
                if manual { player.stopUnplayableCurrent(message: "You're offline") }
                player.retryAfterFailure()
            } else {
                offline = false
                playsOn = nil
                urls.offline = false
                player.isPlayable = { _ in true }
                player.upcomingURLsChanged()
                player.retryAfterFailure()
            }
        }

        for step in 0..<ops {
            let before = player.queue.current?.id
            let op = Int.random(in: 0...13, using: &rng)
            log.append("\(op)")
            switch op {
            case 0: player.play(songs(), startAt: 0)
            case 1, 2:
                // The buffer ran dry (online or off).
                if let c = player.queue.current, currentURL()?.isFileURL == false, player.isPlaying { silent = c.id }
                player.handle(.stalled)
            case 3:
                // Sound: a tick past where it was.
                if let c = player.queue.current {
                    player.handle(.time(c.id, player.position + 1, duration: nil))
                    if silent == c.id { silent = nil }
                }
            case 4: player.toggle(); silent = nil
            case 5: player.seek(Double(Int.random(in: 0...150, using: &rng))); silent = nil
            case 6: player.next()
            case 7: switchTo(offline: true, manual: false)
            case 8: switchTo(offline: true, manual: true)
            case 9: switchTo(offline: false, manual: false)
            case 10:
                // A flip and back within one step (a path blip during a skip).
                player.next()
                switchTo(offline: !offline, manual: false)
                switchTo(offline: !offline, manual: false)
            case 11:
                if let c = player.queue.current { report(.failed(c.id, "boom", undecodable: false)) }
                silent = nil   // that stream is over; whatever plays next is a fresh load
            case 12: sleeps.releaseFirst()
            default: sleeps.releaseAll()
            }
            await drain()
            if player.queue.current?.id != before { silent = nil }
            if player.queue.current?.id != playsOn { playsOn = nil }
            if currentURL()?.isFileURL != false { silent = nil }   // a file, or nothing loaded: no stream to be silent

            let ctx = "seed \(seed) step \(step) ops \(log.joined(separator: ","))"
            PlayerChaosFuzzTests().check(player, engine, ctx)
            if player.isHeldUnplayable {
                #expect(!player.isPlaying && engine.items.isEmpty && !engine.wantsToPlay, "\(ctx): a held song plays or holds a stream")
            }
            if offline, player.isPlaying, let c = player.queue.current, c.id != playsOn {
                #expect(currentURL()?.isFileURL == true, "\(ctx): offline, a stream plays")
            }
            if offline, player.isPlaying, let c = player.queue.current, silent == c.id {
                #expect(player.isStalled, "\(ctx): offline, the stream is silent and nothing waits it out")
                stalledOffline += 1
            }
        }
        sleeps.releaseAll()
        await drain()
        #expect(!player.isStalled, "seed \(seed): a stall still shows after every grace ran (\(log.joined(separator: ",")))")
        return stalledOffline
    }
}
