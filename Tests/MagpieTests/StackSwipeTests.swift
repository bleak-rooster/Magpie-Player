import CoreGraphics
import Testing
@testable import Magpie

/// Fix round 1 (I2): Magpie's own row swipe. It starts only on a horizontal-dominant drag measured by distance, never
/// from the leading edge (the back swipe's), and only a committed release fires an action.
@Suite struct StackSwipeTests {
    @Test func beginsByDistanceWhenMostlyHorizontal() {
        // A slow, deliberate drag: no velocity to speak of, but the distance is plainly sideways.
        #expect(StackSwipeRules.shouldBegin(translation: CGSize(width: -24, height: 2), startX: 200))
        #expect(StackSwipeRules.shouldBegin(translation: CGSize(width: 24, height: -3), startX: 200))
        // Mostly vertical: the scroll view's.
        #expect(!StackSwipeRules.shouldBegin(translation: CGSize(width: 8, height: 12), startX: 200))
        #expect(!StackSwipeRules.shouldBegin(translation: CGSize(width: 10, height: 9), startX: 200), "not dominant enough")
        // Too short to tell.
        #expect(!StackSwipeRules.shouldBegin(translation: CGSize(width: 15, height: 0), startX: 200))
        // From the leading edge: the back swipe's, either direction.
        #expect(!StackSwipeRules.shouldBegin(translation: CGSize(width: 30, height: 0), startX: 12))
        #expect(!StackSwipeRules.shouldBegin(translation: CGSize(width: 30, height: 0), startX: 23.9))
        #expect(StackSwipeRules.shouldBegin(translation: CGSize(width: 30, height: 0), startX: 24))
    }

    @Test func onlyACommittedReleaseFires() {
        let rules = StackSwipeRules(width: 400, leadingCount: 1, trailingCount: 2, leadingFull: true, trailingFull: false)
        // Past half the width and released: the leading edge fires.
        #expect(rules.release(x: 260, velocity: 0, committed: true) == .fire(.leading))
        // The same position, but cancelled or failed (the system took the touch): nothing fires; the row closes.
        #expect(rules.release(x: 260, velocity: 0, committed: false) == .rest(0))
        #expect(rules.release(x: -300, velocity: 0, committed: false) == .rest(0))
        // The trailing edge never full-swipes here (a destructive action is on it): it rests open on both buttons.
        #expect(rules.release(x: -300, velocity: 0, committed: true) == .rest(-152))
        // Short of the reveal: springs back; a flick opens.
        #expect(rules.release(x: 30, velocity: 0, committed: true) == .rest(0))
        #expect(rules.release(x: 30, velocity: 600, committed: true) == .rest(76))
        #expect(rules.release(x: -60, velocity: 0, committed: true) == .rest(-152))
        // No buttons on an edge: never opens that way.
        let leadingOnly = StackSwipeRules(width: 400, leadingCount: 1, trailingCount: 0, leadingFull: true, trailingFull: true)
        #expect(leadingOnly.release(x: -300, velocity: 0, committed: true) == .rest(0))
        #expect(leadingOnly.clamp(-50) == 0 && leadingOnly.clamp(50) == 50)
    }
}
