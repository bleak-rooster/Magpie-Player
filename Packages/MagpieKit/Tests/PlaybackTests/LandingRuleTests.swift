import Testing
@testable import Playback

/// D6: one landing rule for a find that just became ready. It plays at once only when the owner is still on its
/// wait screen and nothing else is playing; otherwise it goes next in the queue with a "Play now" banner.
@Suite struct LandingRuleTests {
    @Test func waitingOnScreenAndNothingPlayingPlays() {
        #expect(LandingRule.landing(waitingOnScreen: true, playing: false) == .play)
    }

    @Test func somethingPlayingQueuesNextWithBanner() {
        #expect(LandingRule.landing(waitingOnScreen: true, playing: true) == .queueNextWithBanner)
    }

    @Test func leftTheWaitScreenQueuesNextWithBanner() {
        #expect(LandingRule.landing(waitingOnScreen: false, playing: false) == .queueNextWithBanner)
        #expect(LandingRule.landing(waitingOnScreen: false, playing: true) == .queueNextWithBanner)
    }

    /// Only the one case plays; the banner is shown exactly when it doesn't.
    @Test(arguments: [false, true], [false, true])
    func bannerExactlyWhenNotPlayed(_ waiting: Bool, _ playing: Bool) {
        let landing = LandingRule.landing(waitingOnScreen: waiting, playing: playing)
        #expect((landing == .play) == (waiting && !playing))
        #expect(landing.showsBanner == !(waiting && !playing))
    }
}
