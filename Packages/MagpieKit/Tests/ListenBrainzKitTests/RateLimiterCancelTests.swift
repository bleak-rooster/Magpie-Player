import Foundation
import Testing
@testable import ListenBrainzKit

/// Round 14 A5 (D99): search reads album tracklists from MusicBrainz as you type, and each new keystroke cancels the
/// last search. A waiter cancelled before its slot gives the slot back, so cancelled searches never push the next
/// one's reads seconds into the future.
@Suite struct RateLimiterCancelTests {
    @Test func cancelledWaitersGiveTheirSlotsBack() async throws {
        let clock = LockedTime(100)
        let limiter = RateLimiter(perSecond: 1, now: { clock.value }, sleep: { _ in throw CancellationError() })
        try await limiter.wait()                       // slot at 100; the next is at 101
        for _ in 0..<5 { try? await limiter.wait() }   // five searches cancelled while waiting
        #expect(await limiter.nextSlotForTests == 101, "not 106")
    }
}

final class LockedTime: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    init(_ t: TimeInterval) { self.t = t }
    var value: TimeInterval { lock.withLock { t } }
    func set(_ v: TimeInterval) { lock.withLock { t = v } }
}
