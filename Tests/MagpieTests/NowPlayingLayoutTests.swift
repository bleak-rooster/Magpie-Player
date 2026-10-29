import CoreGraphics
import DesignSystem
import Testing
@testable import Magpie

/// T10b (D43): Now Playing fits one screen; the art takes what the rest leaves.
@Suite struct NowPlayingLayoutTests {
    /// What the rest of the screen needs at the default text size: top bar 44, title and artist 60, scrubber 50,
    /// transport 76, bottom row 44, padding 32, Up next 52 and 7 gaps of 20.
    private static let realisticReserved: CGFloat = 44 + 60 + 50 + 76 + 44 + 32 + 52 + 7 * 20

    @Test func smallestPhoneArtFitsTheWidth() {
        // 375 × 667 less the sheet's top inset and the 24 pt side margins.
        let available = CGSize(width: 375 - 48, height: 667 - 40)
        let side = NowPlayingLayout.artSide(available: available, reserved: Self.realisticReserved)
        #expect(side >= 120)
        #expect(side <= available.width)
        #expect(side == available.height - Self.realisticReserved)   // flexes, not capped
    }

    @Test func largestPhoneIsCappedAt360() {
        let side = NowPlayingLayout.artSide(available: CGSize(width: 440, height: 956), reserved: Self.realisticReserved)
        #expect(side == 360)
    }

    @Test func narrowWidthWins() {
        #expect(NowPlayingLayout.artSide(available: CGSize(width: 300, height: 2000), reserved: 100) == 300)
    }

    @Test func tinyHeightClampsTo120() {
        #expect(NowPlayingLayout.artSide(available: CGSize(width: 375, height: 300), reserved: Self.realisticReserved) == 120)
        #expect(NowPlayingLayout.artSide(available: CGSize(width: 375, height: 300), reserved: 290, minSide: 100) == 100)
    }

    @Test func upNextGoesWhenMinArtCannotFit() {
        let reserved: CGFloat = 500
        #expect(NowPlayingLayout.showsUpNext(available: CGSize(width: 327, height: 619), reserved: reserved) == false)
        #expect(NowPlayingLayout.showsUpNext(available: CGSize(width: 327, height: 620), reserved: reserved) == true)
        #expect(NowPlayingLayout.showsUpNext(available: CGSize(width: 327, height: 900), reserved: reserved) == true)
    }

    /// Drop Up next first, then the spacing goes from xl to m.
    @Test func planDropsUpNextThenTightensSpacing() {
        let parts: CGFloat = 44 + 60 + 50 + 76 + 44 + 32   // 306, padding included
        let gaps = 5
        let upNext: CGFloat = 52
        let xl = Tokens.Spacing.xl, m = Tokens.Spacing.m

        // Roomy: everything at xl.
        let roomy = NowPlayingLayout.plan(available: CGSize(width: 327, height: 900), parts: parts, gaps: gaps, upNext: upNext)
        #expect(roomy == .init(side: 327, showsUpNext: true, spacing: xl))

        // Up next plus its gap (72) no longer fits beside 120 pt of art; without it, xl still fits.
        let withUpNextAtXL = parts + CGFloat(gaps + 1) * xl + upNext                 // 478
        let h1 = withUpNextAtXL + 119
        let noUpNext = NowPlayingLayout.plan(available: CGSize(width: 327, height: h1), parts: parts, gaps: gaps, upNext: upNext)
        #expect(noUpNext.showsUpNext == false)
        #expect(noUpNext.spacing == xl)
        #expect(noUpNext.side == h1 - (parts + CGFloat(gaps) * xl))

        // Even without Up next, xl doesn't fit: spacing tightens to m.
        let h2 = parts + CGFloat(gaps) * xl + 110
        let tight = NowPlayingLayout.plan(available: CGSize(width: 327, height: h2), parts: parts, gaps: gaps, upNext: upNext)
        #expect(tight == .init(side: h2 - (parts + CGFloat(gaps) * m), showsUpNext: false, spacing: m))

        // No next song: nothing to show, and the plan doesn't pretend there is.
        let none = NowPlayingLayout.plan(available: CGSize(width: 327, height: 800), parts: parts, gaps: gaps, upNext: nil)
        #expect(none.showsUpNext == false)
        #expect(none.spacing == xl)
    }
}
