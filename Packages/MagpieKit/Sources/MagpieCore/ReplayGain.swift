import Foundation

public extension ReplayGainMode {
    /// The range a gain is clamped to, in dB. Attenuation only: AVPlayer volume can't exceed 1, and an audio
    /// tap would put gapless and CarPlay playback at risk, so loud masters come down and quiet ones play as
    /// recorded.
    static let gainRange: ClosedRange<Double> = -15...0

    /// The linear volume (0…1) a song plays at in this mode. Track uses the track gain and peak, falling back
    /// to the album's; Album the other way round. Off, or a song without gain tags, plays at unity gain.
    /// The volume is also capped so that volume × peak ≤ 1 when the peak is above 1.
    func volume(for gain: ReplayGain?) -> Float {
        guard let gain else { return 1 }
        let tag: (dB: Double?, peak: Double?) = switch self {
        case .off: (nil, nil)
        case .track: gain.trackGain != nil ? (gain.trackGain, gain.trackPeak) : (gain.albumGain, gain.albumPeak)
        case .album: gain.albumGain != nil ? (gain.albumGain, gain.albumPeak) : (gain.trackGain, gain.trackPeak)
        }
        guard let dB = tag.dB, dB.isFinite else { return 1 }
        let clamped = min(max(dB, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        var volume = pow(10, clamped / 20)
        if let peak = tag.peak, peak.isFinite, peak > 0 { volume = min(volume, 1 / peak) }
        return Float(volume)
    }
}
