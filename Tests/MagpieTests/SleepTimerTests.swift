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

/// Records the duration, then waits (cancellably) so a timer can be cancelled mid-sleep.
struct SuspendingSleep: Sendable {
    func sleep(_ d: Duration) async throws { try await Task.sleep(for: .seconds(3600)) }
}

private func close(_ a: [Float], _ b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.001 }
}

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

@MainActor @Suite struct SleepTimerTests {
    let engine = FakeEngine()
    func player() -> Player {
        let p = Player(engine: engine, scrobbler: FakeScrobbler(), urls: FakeURLs())
        p.play([PlayerTests.song("1"), PlayerTests.song("2")], startAt: 0)
        return p
    }

    @Test func fadesThenPauses() async {
        let recorder = SleepRecorder(); let p = player()
        let timer = SleepTimer(player: p, sleep: { await recorder.record($0) })
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
        p.handle(.ended)                       // the song finished; Player clears the flag
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
}
