import CoreGraphics
import Testing
@testable import Magpie

/// QC (crash report #5): a measured Now Playing height is stored in whole pixels, and only when it moved by half a
/// point or more, so float noise between layout passes can't make the page lay out again and again.
@Suite struct MeasuredHeightTests {
    @Test func firstMeasureIsStoredInWholePixels() {
        #expect(MeasuredHeight.toStore(52.33333333333337, over: nil, scale: 3) == 157.0 / 3)
        #expect(MeasuredHeight.toStore(44, over: nil, scale: 3) == 44)
        #expect(MeasuredHeight.toStore(49.1, over: nil, scale: 2) == 49.5)
    }

    /// 52.333 measured again as 52.333 (a different float) is the same height.
    @Test func jitterIsNotStored() {
        let stored = MeasuredHeight.toStore(52.33333333333337, over: nil, scale: 3)
        #expect(MeasuredHeight.toStore(52.333333333333258, over: stored, scale: 3) == nil)
        #expect(MeasuredHeight.toStore(52.33333333333337, over: stored, scale: 3) == nil)
        // The pair that looped behind the Queue sheet (T10b measured the scaled frame).
        let scrubber = MeasuredHeight.toStore(45.40630182421228, over: nil, scale: 3)
        #expect(MeasuredHeight.toStore(45.406301824212164, over: scrubber, scale: 3) == nil)
    }

    /// At 2x the same holds: a re-measure a float apart, or across a pixel edge, keeps what is stored.
    @Test func jitterAtScaleTwoIsNotStored() {
        let stored = MeasuredHeight.toStore(52.25, over: nil, scale: 2)
        #expect(stored == 52.5)
        #expect(MeasuredHeight.toStore(52.250000000001, over: stored, scale: 2) == nil)
        let edge = MeasuredHeight.toStore(52.0, over: nil, scale: 2)
        #expect(edge == 52)
        #expect(MeasuredHeight.toStore(52.000000001, over: edge, scale: 2) == nil)
        #expect(MeasuredHeight.toStore(51.999999999, over: edge, scale: 2) == nil)
    }

    /// Noise either side of a pixel edge rounds to the same pixel.
    @Test func noiseAtAPixelEdgeRoundsTheSameWay() {
        #expect(MeasuredHeight.pixelRounded(52.000000001, scale: 2) == 52)
        #expect(MeasuredHeight.pixelRounded(51.999999999, scale: 2) == 52)
        #expect(MeasuredHeight.pixelRounded(52.2, scale: 2) == 52.5)
    }

    /// Under half a point is the same height (one pixel at 3x); half a point or more is a real change.
    @Test func realChangesAreStored() {
        #expect(MeasuredHeight.toStore(52 + 1.0 / 3, over: 52, scale: 3) == nil)
        #expect(MeasuredHeight.toStore(52.5, over: 52, scale: 2) == 52.5)
        #expect(MeasuredHeight.toStore(53, over: 52, scale: 1) == 53)
        #expect(MeasuredHeight.toStore(80.33, over: 49.33, scale: 3) == 241.0 / 3)
    }
}
