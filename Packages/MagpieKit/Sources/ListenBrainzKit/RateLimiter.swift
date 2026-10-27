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
        nextSlot = start + interval
        if start > t { try await sleep(start - t) }
    }
}
