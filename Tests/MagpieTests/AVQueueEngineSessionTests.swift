import AVFoundation
import Foundation
import MagpieCore
import os
import Playback
import Testing

/// QC (crash report #2): the audio session is activated off the main thread (it can block on a route change or an
/// interruption), only on the first play, and playback starts once it is active. A failed activation is logged and
/// playback goes ahead; the next play tries again.
@MainActor
@Suite struct AVQueueEngineSessionTests {
    /// Stands in for `AVAudioSession.setActive(true)`: records where it ran and takes `delay` to answer.
    final class Activation: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (calls: 0, onMain: [Bool]()))
        let delay: TimeInterval
        let fails: Bool
        init(delay: TimeInterval = 0.3, fails: Bool = false) { self.delay = delay; self.fails = fails }

        var calls: Int { state.withLock { $0.calls } }
        var onMain: [Bool] { state.withLock { $0.onMain } }

        func activate() throws {
            state.withLock { $0.calls += 1; $0.onMain.append(Thread.isMainThread) }
            Thread.sleep(forTimeInterval: delay)
            if fails { throw CocoaError(.featureUnsupported) }
        }
    }

    @Test func activatesOffMainOnceThenPlays() async throws {
        let wav = try AVQueueEngineTests.silentWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        let activation = Activation()
        let engine = AVQueueEngine(activateSession: { try activation.activate() })
        engine.setItems([(UUID(), wav)], startAt: 0)

        let clock = ContinuousClock()
        let elapsed = clock.measure { engine.play() }
        #expect(elapsed < .milliseconds(100), "play() doesn't wait for the session: \(elapsed)")
        #expect(engine.playerRate == 0, "nothing plays before the session is active")
        engine.play()                                    // a second tap while it activates
        try await AVQueueEngineTests.waitUntil { engine.playerRate > 0 }
        #expect(activation.calls == 1)
        #expect(activation.onMain == [false], "activated off the main thread")

        engine.pause()
        #expect(engine.playerRate == 0)
        engine.play()
        #expect(engine.playerRate > 0, "already active: plays at once")
        #expect(activation.calls == 1, "only the first play activates")
    }

    @Test func pauseWhileActivatingStaysPaused() async throws {
        let wav = try AVQueueEngineTests.silentWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        let activation = Activation()
        let engine = AVQueueEngine(activateSession: { try activation.activate() })
        engine.setItems([(UUID(), wav)], startAt: 0)
        engine.play()
        engine.pause()
        try await AVQueueEngineTests.waitUntil { activation.calls == 1 }
        try await Task.sleep(for: .milliseconds(600))
        #expect(engine.playerRate == 0, "the pause wins")
    }

    /// Streams every song from one local file.
    @MainActor final class FileURLs: StreamURLProvider {
        let file: URL
        init(_ file: URL) { self.file = file }
        func streamURL(for song: Song) -> URL { file }
    }

    /// QC fix 1: an interruption while the activation is in flight wins. When the activation completes nothing plays,
    /// and the player shows paused.
    @Test func interruptionDuringActivationWins() async throws {
        let wav = try AVQueueEngineTests.silentWAV(seconds: 10)
        defer { try? FileManager.default.removeItem(at: wav) }
        let activation = Activation(delay: 0.3)
        let engine = AVQueueEngine(activateSession: { try activation.activate() })
        let player = Player(engine: engine, scrobbler: FakeScrobbler(), urls: FileURLs(wav))
        player.play([Song(id: "s1", title: "T", artist: "A", album: "B", duration: 10)], startAt: 0)
        #expect(player.isPlaying)
        try await AVQueueEngineTests.waitUntil { activation.calls == 1 }
        NotificationCenter.default.post(name: AVAudioSession.didBecomeInactiveNotification,
                                        object: AVAudioSession.sharedInstance())
        try await Task.sleep(for: .milliseconds(700))      // the activation has completed by now
        #expect(engine.playerRate == 0, "no play after the interruption")
        #expect(!player.isPlaying)
    }

    @Test func failedActivationStillPlaysAndIsTriedAgain() async throws {
        let wav = try AVQueueEngineTests.silentWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        let activation = Activation(delay: 0.05, fails: true)
        let engine = AVQueueEngine(activateSession: { try activation.activate() })
        engine.setItems([(UUID(), wav)], startAt: 0)
        engine.play()
        try await AVQueueEngineTests.waitUntil { engine.playerRate > 0 }
        engine.pause()
        engine.play()
        try await AVQueueEngineTests.waitUntil { activation.calls == 2 }
        #expect(activation.onMain == [false, false])
    }
}
