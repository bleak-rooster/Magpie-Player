import Foundation
import Testing
import MagpieCore

@Suite struct ReplayGainTests {
    @Test func trackModeAttenuates() {
        #expect(abs(ReplayGainMode.track.volume(for: ReplayGain(trackGain: -6)) - 0.501187) < 0.0001)
        #expect(ReplayGainMode.track.volume(for: ReplayGain(trackGain: 3)) == 1)
        #expect(abs(ReplayGainMode.track.volume(for: ReplayGain(trackGain: -20)) - 0.177828) < 0.0001)
    }

    @Test func albumModeAndFallbacks() {
        #expect(abs(ReplayGainMode.album.volume(for: ReplayGain(trackGain: -3, albumGain: -9)) - 0.354813) < 0.0001)
        #expect(abs(ReplayGainMode.album.volume(for: ReplayGain(trackGain: -6)) - 0.501187) < 0.0001)
        #expect(ReplayGainMode.off.volume(for: ReplayGain(trackGain: -6)) == 1)
        #expect(ReplayGainMode.track.volume(for: nil) == 1)
    }
}
