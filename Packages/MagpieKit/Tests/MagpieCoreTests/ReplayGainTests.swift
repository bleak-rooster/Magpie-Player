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

    @Test func peakAboveOneCapsTheVolume() {
        #expect(abs(ReplayGainMode.track.volume(for: ReplayGain(trackGain: -1, trackPeak: 1.25)) - 0.8) < 0.0001)
        #expect(abs(ReplayGainMode.album.volume(for: ReplayGain(trackGain: -1, albumGain: -1, trackPeak: 0.5, albumPeak: 1.25)) - 0.8) < 0.0001)
        #expect(abs(ReplayGainMode.track.volume(for: ReplayGain(trackGain: -6, trackPeak: 1)) - 0.501187) < 0.0001)
        #expect(abs(ReplayGainMode.track.volume(for: ReplayGain(trackGain: -6, trackPeak: 0.9)) - 0.501187) < 0.0001)
        #expect(abs(ReplayGainMode.track.volume(for: ReplayGain(trackGain: -1, trackPeak: 0.98)) - 0.891251) < 0.0001)
        #expect(ReplayGainMode.off.volume(for: ReplayGain(trackGain: -1, trackPeak: 1.25)) == 1)
    }
}
