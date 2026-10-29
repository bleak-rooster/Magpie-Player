import Foundation
import Testing
import MagpieCore
import Playback
@testable import Magpie

/// Records each duration and returns at once.
actor SleepRecorder {
    private(set) var durations: [Duration] = []
    func record(_ d: Duration) { durations.append(d) }
}

/// Waits (cancellably) without returning, so a timer can be cancelled mid-sleep. Records nothing.
struct SuspendingSleep: Sendable {
    func sleep(_ d: Duration) async throws { try await Task.sleep(for: .seconds(3600)) }
}

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock(); private var t: Date
    init(_ t: Date) { self.t = t }
    var date: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

/// Returns at once for the first `free` calls (the first moves the clock past a 15 minute deadline), then suspends.
final class GatedSleep: @unchecked Sendable {
    private let lock = NSLock(); private var calls = 0
    let free: Int; let clock: TestClock
    init(free: Int, clock: TestClock) { self.free = free; self.clock = clock }
    func sleep(_ d: Duration) async throws {
        let n = lock.withLock { calls += 1; return calls }
        if n == 1 { clock.advance(900) }
        if n > free { try await Task.sleep(for: .seconds(3600)) }
    }
}

private func close(_ a: [Float], _ b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.001 }
}

@MainActor @Suite struct SleepTimerTests {
    let engine = FakeEngine()
    func player() -> Player {
        let p = Player(engine: engine, scrobbler: FakeScrobbler(), urls: FakeURLs())
        p.play([PlayerTests.song("1"), PlayerTests.song("2")], startAt: 0)
        return p
    }

    @Test func fadesThenPauses() async {
        let recorder = SleepRecorder(); let p = player(); let clock = TestClock(.init(timeIntervalSince1970: 0))
        let timer = SleepTimer(player: p, now: { clock.date }, sleep: { d in
            await recorder.record(d)
            if d == .seconds(900) { clock.advance(900) }
        })
        timer.start(.m15)
        await timer.settled()
        #expect(await recorder.durations == [.seconds(900)] + Array(repeating: .milliseconds(500), count: 10))
        #expect(close(engine.setVolumeCalls, [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0.0, 1.0]))
        #expect(!p.isPlaying && timer.mode == .off)
    }

    @Test func atModeCountsDown() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timer = SleepTimer(player: player(), now: { start }, sleep: SuspendingSleep().sleep)
        timer.start(.m30)
        #expect(timer.mode == .at(start.addingTimeInterval(1800)))
        #expect(timer.remaining(at: start.addingTimeInterval(600)) == 1200)
        timer.cancel()
    }

    @Test func endOfSongStopsAfterCurrentThenResetsToOff() async {
        let p = player(); let timer = SleepTimer(player: p, sleep: SuspendingSleep().sleep)
        timer.start(.endOfSong)
        #expect(p.stopsAfterCurrent && timer.mode == .endOfSong)
        p.handle(.ended(p.queue.current!.id))                     // the song finished; Player clears the flag
        #expect(!p.stopsAfterCurrent && !p.isPlaying)
        #expect(await eventually { timer.mode == .off })
    }

    @Test func cancelRestoresVolumeAndClears() async {
        let p = player(); let timer = SleepTimer(player: p, sleep: SuspendingSleep().sleep)
        timer.start(.endOfSong); timer.cancel()
        #expect(!p.stopsAfterCurrent && timer.mode == .off)
        timer.start(.m30); timer.cancel(); await timer.settled()
        #expect(engine.setVolumeCalls.last == 1 && timer.mode == .off && p.isPlaying)
    }

    @Test func voiceOverValue() {
        #expect(SleepTimerMenu.value(.off, remaining: nil) == "Off")
        #expect(SleepTimerMenu.value(.endOfSong, remaining: nil) == "End of song")
        #expect(SleepTimerMenu.value(.at(.now), remaining: 12 * 60) == "Sleeping in 12 minutes")
        #expect(SleepTimerMenu.value(.at(.now), remaining: 20) == "Sleeping in 1 minute")
    }

    @Test func firesAtTheDeadlineWhenASleepReturnsEarly() async {
        let recorder = SleepRecorder(); let p = player(); let clock = TestClock(.init(timeIntervalSince1970: 0))
        let timer = SleepTimer(player: p, now: { clock.date }, sleep: { d in
            await recorder.record(d)
            switch await recorder.durations.count {
            case 1: clock.advance(100)       // returned early
            case 2: clock.advance(800)
            default: break
            }
        })
        timer.start(.m15)
        await timer.settled()
        #expect(await recorder.durations.prefix(2) == [.seconds(900), .seconds(800)])
        #expect(await recorder.durations.count == 12 && !p.isPlaying && timer.mode == .off)
    }

    @Test func cancelMidFadeRestoresVolumeWithoutPausing() async {
        let p = player(); let clock = TestClock(.init(timeIntervalSince1970: 0))
        let gate = GatedSleep(free: 3, clock: clock)    // 900 s + two fade steps, then stuck
        let timer = SleepTimer(player: p, now: { clock.date }, sleep: gate.sleep)
        timer.start(.m15)
        #expect(await eventually { close(engine.setVolumeCalls, [0.9, 0.8, 0.7]) })
        timer.cancel(); await timer.settled()
        #expect(engine.setVolumeCalls.last == 1 && p.volume == 1 && p.isPlaying && timer.mode == .off)
    }

    @Test func skipDuringEndOfSongPlaysTheNextSongAndResets() async {
        let p = player(); let timer = SleepTimer(player: p, sleep: SuspendingSleep().sleep)
        timer.start(.endOfSong)
        p.next()
        #expect(p.queue.current?.song.id == "2" && p.isPlaying && !p.stopsAfterCurrent)
        #expect(await eventually { timer.mode == .off })
    }
}
