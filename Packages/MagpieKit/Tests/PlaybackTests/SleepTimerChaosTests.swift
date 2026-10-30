import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import Playback

/// Crash hunt 1: the sleep timer's fade under chaos (starts, cancels, skips and pauses mid-fade, songs ending). After
/// everything settles the volume is back to 1 unless a fade is still running, and an end-of-song timer always matches
/// the player's stop-after-current flag.
@MainActor
@Suite struct SleepTimerChaosTests {
    typealias Fuzz = PlayerChaosFuzzTests

    @Test func chaosSequences() async {
        for seed in 0..<UInt64(300) {
            var rng = SeededRNG(seed: seed &+ 7)
            let engine = Fuzz.ChaosEngine()
            let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: Fuzz.ChaosURLs())
            var clock = Date(timeIntervalSince1970: 1_800_000_000)
            // Sleeps return at once (or after a yield), so a timer reaches its fade within the sequence.
            let timer = SleepTimer(player: player, now: { clock }, sleep: { _ in await Task.yield() })
            player.play((0..<4).map { Song(id: "s\($0)", title: "T", artist: "A", album: "B", duration: 200) }, startAt: 0)
            for step in 0..<40 {
                switch Int.random(in: 0...7, using: &rng) {
                case 0, 1: timer.start(SleepTimerOption.allCases.randomElement(using: &rng)!)
                case 2: timer.cancel()
                case 3: player.toggle()
                case 4: player.next()
                case 5:
                    if let last = engine.items.last?.0 {
                        engine.willReport(.ended(last))
                        player.handle(.ended(last))
                    }
                case 6: clock = clock.addingTimeInterval([1, 60, 3600, -60].randomElement(using: &rng)!)
                default: for _ in 0..<Int.random(in: 0...12, using: &rng) { await Task.yield() }
                }
                #expect(engine.volume >= 0 && engine.volume <= 1, "seed \(seed) step \(step)")
                for _ in 0..<5 { await Task.yield() }
                // The timer watches the flag through Observations: wait (bounded) for it to catch up, rather than count
                // on how many hops Observations takes to deliver (merged crash-hunt review, M8).
                var hops = 0
                while timer.mode == .endOfSong, !player.stopsAfterCurrent, hops < 1_000 { await Task.yield(); hops += 1 }
                if timer.mode == .endOfSong {
                    #expect(player.stopsAfterCurrent, "seed \(seed) step \(step): an end-of-song timer without the flag")
                }
            }
            timer.cancel()
            await timer.settled()
            for _ in 0..<20 { await Task.yield() }
            #expect(timer.mode == .off && player.volume == 1 && engine.volume == 1, "seed \(seed): volume left at \(player.volume)")
        }
    }
}
