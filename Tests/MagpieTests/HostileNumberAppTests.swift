import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Magpie

/// Crash hunt 4 (with hunters 1 and 2): numbers the servers send are only bounded by JSON. A length of `1e17` seconds or
/// more is finite, so `isFinite` guards let it through, and `Int(_:)` then traps past `Int.max`. Every app formatter
/// that makes whole numbers of server data holds for every value. (`ScrobbleRouter.listen` is fixed and tested on
/// hunters 1 and 2's branches.)
@MainActor
@Suite struct HostileNumberAppTests {
    static let hostile: [Double] = [.nan, .infinity, -.infinity, 1e300, -1e300, .greatestFiniteMagnitude,
                                    -.greatestFiniteMagnitude, 1e17, 9.3e18, 1e16, 5e-324, -1, 0, 0.4, 59.5, 3599.6, 1e9]

    /// `BringInCopy.size`: Lidarr's `duration` (milliseconds) of a release, summed over the releases offered.
    @Test func bringInSizeHoldsForHugeLengths() {
        // A length no release has reads as unknown, like a missing one.
        #expect(BringInCopy.size(1e300) == nil && BringInCopy.size(.greatestFiniteMagnitude) == nil)
        for d in Self.hostile { _ = BringInCopy.size(d) }
        #expect(BringInCopy.size(6_600) == "about 2 hours of music")
        #expect(BringInCopy.size(.infinity) == nil && BringInCopy.size(.nan) == nil && BringInCopy.size(-1) == nil)
    }

    /// `FindsShelf.daysLeft`: a find's `createdAt`, from the server or a saved snapshot of it.
    @Test func findDaysLeftHoldsForAnyDate() {
        let now = Date(timeIntervalSince1970: 1.8e9)
        for t in Self.hostile + [-1.8e9, 1.8e9 + 86_400 * 3] {
            let days = FindsShelf.daysLeft(since: Date(timeIntervalSince1970: t), now: now)
            #expect((0...FindsShelf.sampleDays).contains(days))
        }
        #expect(FindsShelf.daysLeft(since: now.addingTimeInterval(-86_400 * 3), now: now) == 4)
    }

    /// `DurationText.spoken` (VoiceOver's song length and position): DateComponentsFormatter raised
    /// NSInternalInconsistencyException ("isfinite(timeInterval)") on NaN or infinity.
    @Test func spokenDurationHoldsForNonFiniteValues() {
        #expect(DurationText.spoken(.nan) == DurationText.spoken(0))
        #expect(DurationText.spoken(.infinity) == DurationText.spoken(0))
        #expect(DurationText.spoken(-.infinity) == DurationText.spoken(0))
        #expect(!DurationText.spoken(238).isEmpty)
    }

    /// The other formatters of server numbers, swept with every hostile value (seeded).
    @Test func formattersHoldForEveryValue() {
        var rng = SeededRNG(seed: 0xF0_4A7)
        for _ in 0..<5_000 {
            let d = Bool.random(using: &rng) ? Self.hostile.randomElement(using: &rng)! : Double.random(in: -1e20...1e20, using: &rng)
            _ = DurationText.clock(d)
            _ = DurationText.spoken(d)
            _ = DurationText.minutes(d)
            _ = RequestCopy.percent(d)
            _ = BringInCopy.size(d)
            _ = FindsShelf.daysLeft(since: Date(timeIntervalSince1970: d), now: .now)
        }
    }
}
