import Foundation

public extension ReplayGainMode {
    /// The range a gain is clamped to, in dB. Attenuation only: AVPlayer volume can't exceed 1, and an audio
    /// tap would put gapless and CarPlay playback at risk, so loud masters come down and quiet ones play as
    /// recorded. Peaks are ignored.
    static let gainRange: ClosedRange<Double> = -15...0

    /// The linear volume (0…1) a song plays at in this mode. Track uses the track gain, falling back to the
    /// album gain; Album the other way round. Off, or a song without tags, plays at unity gain.
    func volume(for gain: ReplayGain?) -> Float {
        let dB: Double? = switch self {
        case .off: nil
        case .track: gain?.trackGain ?? gain?.albumGain
        case .album: gain?.albumGain ?? gain?.trackGain
        }
        guard let dB, dB.isFinite else { return 1 }
        let clamped = min(max(dB, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        return Float(pow(10, clamped / 20))
    }
}
