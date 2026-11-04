import Foundation

/// Spaces calls at least `1 / perSecond` apart (MusicBrainz asks for at most one request per second, A8).
/// Slots are reserved before sleeping, so concurrent callers queue up in order instead of bursting.
/// The clock and sleep are injected so tests never really wait.
public actor RateLimiter {
    public typealias Clock = @Sendable () -> TimeInterval
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let interval: TimeInterval
    private let now: Clock
    private let sleep: Sleeper
    private var nextSlot: TimeInterval?

    public init(perSecond: Double = 1,
                now: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }) {
        self.interval = 1 / max(perSecond, 0.001)
        self.now = now
        self.sleep = sleep
    }

    /// Returns once the caller's slot has arrived. Throws if the sleep is cancelled.
    public func wait() async throws {
        let t = now()
        let start = max(t, nextSlot ?? t)
        let slot = start + interval
        nextSlot = slot
        guard start > t else { return }
        do {
            try await sleep(start - t)
        } catch {
            // Round 14 (D99): cancelled before its turn (search typed on): the slot goes back when no one queued
            // behind it, so cancelled searches don't push the next one's requests into the future.
            if nextSlot == slot { nextSlot = start }
            throw error
        }
    }

    var nextSlotForTests: TimeInterval? { nextSlot }
}
