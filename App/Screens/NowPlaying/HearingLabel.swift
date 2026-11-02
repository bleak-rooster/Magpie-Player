import DesignSystem
import MagpieCore
import SwiftUI

/// Round 12 Y3 (plan item 11): what Now Playing says under the scrubber, about what you actually hear, and the
/// hallmark that goes with it. The hallmark used to show the original file's quality even while a transcode played.
///
/// - "Lossless · FLAC 24/96": the original lossless file.
/// - "MP3 320": a lossy original.
/// - "Transcoded · Opus 160 kbps (from FLAC)": the server converts it.
/// - "On this iPhone · …": a download (or a song kept from playing), in the quality it was saved in.
///
/// A transcode the server can't do falls back to the original (`SongInfo.Source.stream(.original)`): the label then
/// says the original, and the fallback hint above stays.
struct HearingLabel: Equatable {
    /// The line under the scrubber; nil when nothing is known about the file (no line).
    var text: String?
    /// Whether the sound is a conversion, not the file itself: then there's no Lossless hallmark.
    var transcoded: Bool

    init(source: SongInfo.Source, suffix: String?, bitRate: Int?, samplingRate: Int?, bitDepth: Int?) {
        let original = Self.original(suffix: suffix, bitRate: bitRate, samplingRate: samplingRate, bitDepth: bitDepth)
        switch source {
        case .stream(let quality):
            if Self.isConversion(quality, suffix: suffix, bitRate: bitRate) {
                transcoded = true
                text = "Transcoded \u{00B7} " + Self.converted(quality, suffix: suffix)
            } else {
                transcoded = false
                text = original
            }
        case .onPhone(let quality):
            transcoded = Self.isConversion(quality, suffix: suffix, bitRate: bitRate)
            let what = transcoded ? Self.converted(quality, suffix: suffix) : original
            text = ["On this iPhone", what].compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
    }

    /// Whether `quality` changes the file: Original never does, and the server sends the file as it is when it's
    /// already in that format at no more than that bit rate.
    static func isConversion(_ quality: StreamQuality, suffix: String?, bitRate: Int?) -> Bool {
        guard let cap = quality.maxBitRate else { return false }
        if let suffix, suffix.lowercased() == quality.format, let bitRate, bitRate > 0, bitRate <= cap { return false }
        return true
    }

    /// "Opus 160 kbps (from FLAC)".
    static func converted(_ quality: StreamQuality, suffix: String?) -> String {
        quality.shortTitle + (suffix.flatMap { $0.isEmpty ? nil : " (from \($0.uppercased()))" } ?? "")
    }

    /// The original file: "Lossless · FLAC 24/96", "Lossless · FLAC", "MP3 320", "OGG"; nil with no format.
    static func original(suffix: String?, bitRate: Int?, samplingRate: Int?, bitDepth: Int?) -> String? {
        guard let suffix, !suffix.isEmpty else { return nil }
        let name = suffix.uppercased()
        if Quality.from(suffix: suffix, bitRate: bitRate) == .lossless {
            guard let bitDepth, bitDepth > 0, let samplingRate, samplingRate > 0 else { return "Lossless \u{00B7} \(name)" }
            return "Lossless \u{00B7} \(name) \(bitDepth)/\(kHz(samplingRate))"
        }
        guard let bitRate, bitRate > 0 else { return name }
        return "\(name) \(bitRate)"
    }

    /// 96000 → "96"; 44100 → "44.1".
    static func kHz(_ hz: Int) -> String {
        (Double(hz) / 1000).formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    /// The hallmark to show: the song's own (Lossless, or Lossless soon for a kept find) unless what plays is a
    /// conversion, which has none.
    func hallmark(_ songQuality: Quality) -> Quality { transcoded ? .standard : songQuality }
}

extension AppModel {
    /// Where the sound of `song` comes from now: the phone's copy, the original after a failed transcode, or a
    /// stream at the current quality. The same rule as Song info, answered without a wait.
    func playingSource(_ song: Song) -> SongInfo.Source {
        if let downloads, downloads.localFiles[song.id] != nil, let quality = downloads.localQualities[song.id] {
            return .onPhone(quality)
        }
        if player.lastFallbackSongId == song.id { return .stream(.original) }   // the transcode failed (Task 7)
        return .stream(currentStreamQuality)
    }

    /// Now Playing's line and hallmark for `song`.
    func hearing(_ song: Song) -> HearingLabel {
        HearingLabel(source: playingSource(song), suffix: song.suffix, bitRate: song.bitRate,
                     samplingRate: song.samplingRate, bitDepth: song.bitDepth)
    }
}
