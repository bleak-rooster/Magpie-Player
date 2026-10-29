import Foundation
import MagpieCore
import Observation

/// Sleep timer: after a set time the music fades out over 5 s and pauses, or it stops when the current song
/// ends. The fade moves `Player.volume`, which the engine multiplies with each song's own (ReplayGain) volume,
/// so levelling is never overwritten; cancelling puts the volume back to 1.
@MainActor @Observable
public final class SleepTimer {
    public enum Mode: Equatable, Sendable { case off, at(Date), endOfSong }

    public private(set) var mode: Mode = .off

    /// Chosen behaviour: once the fade starts it runs to the end whatever the listener does. Skipping a song or
    /// pausing and resuming doesn't stop or restart it; only `cancel()` does (the Off menu item, sign out).
    /// 10 steps of 0.5 s: 0.9 … 0.0 (5 s).
    static let fadeSteps = 10
    static let fadeStep: Duration = .milliseconds(500)

    @ObservationIgnored private let player: Player
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    public init(player: Player, now: @escaping () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.player = player
        self.now = now
        self.sleep = sleep
    }

    public func start(_ option: SleepTimerOption) {
        stopTasks()
        if player.volume != 1 { player.volume = 1 }
        guard let seconds = option.seconds else {
            mode = .endOfSong
            player.stopsAfterCurrent = true
            // The Player clears the flag when the song ends; the timer is then spent.
            watchTask = Task { [weak self, player] in
                let flag = Observations { @MainActor in player.stopsAfterCurrent }
                for await on in flag {
                    guard let self else { return }
                    if !on, self.mode == .endOfSong { self.mode = .off }
                    if self.mode != .endOfSong { return }
                }
            }
            return
        }
        player.stopsAfterCurrent = false
        mode = .at(now().addingTimeInterval(seconds))
        timerTask = Task { [weak self, sleep, now] in
            do {
                try await sleep(.seconds(seconds))
                // The sleep can end early or late (backgrounding); fire at the displayed deadline.
                while let self, let left = self.remaining(at: now()), left > 0 {
                    try await sleep(.seconds(left))
                }
                for step in 1...Self.fadeSteps {
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.player.volume = Float(Self.fadeSteps - step) / Float(Self.fadeSteps)
                    try await sleep(Self.fadeStep)
                }
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            if self.player.isPlaying { self.player.toggle() }
            self.player.volume = 1
            self.mode = .off
        }
    }

    public func cancel() {
        stopTasks()
        player.volume = 1
        player.stopsAfterCurrent = false
        mode = .off
    }

    /// Seconds left on a minutes timer; nil when off or waiting for the end of the song.
    public func remaining(at date: Date) -> TimeInterval? {
        guard case .at(let end) = mode else { return nil }
        return max(0, end.timeIntervalSince(date))
    }

    /// Tests: waits for the timer task to finish.
    public func settled() async {
        await timerTask?.value
    }

    private func stopTasks() {
        timerTask?.cancel()
        watchTask?.cancel()
    }
}
