import Foundation

/// A transcode preset's level (R5).
public enum QualityLevel: String, CaseIterable, Codable, Hashable, Sendable {
    case high, medium, low

    public var title: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}

/// What a song streams or downloads as (R5): Original, or a format × High / Medium / Low preset.
///
/// | Format | High | Medium | Low |
/// | MP3    | 320  | 192    | 128 |
/// | AAC    | 256  | 160    | 96  |
/// | Opus   | 320  | 160    | 96  |
///
/// AAC and Opus stream chunked (D42, D45: iOS 27 AVFoundation plays Navidrome's Ogg Opus, though Ogg durations are
/// estimates). The stored name is the format and bit rate, so a preset kept from before keeps its name; a saved bit
/// rate that is no longer a preset decodes as the nearest preset of its format, a tie going up (`init(migrating:)`).
public enum StreamQuality: String, CaseIterable, Hashable, Sendable {
    case original = "original"
    case aacHigh = "aac256", aacMedium = "aac160", aacLow = "aac96"
    case opusHigh = "opus320", opusMedium = "opus160", opusLow = "opus96"
    case mp3High = "mp3_320", mp3Medium = "mp3_192", mp3Low = "mp3_128"

    /// The `format` parameter of `stream`: "raw", "aac", "opus" or "mp3".
    public var format: String {
        switch self {
        case .original: "raw"
        case .aacHigh, .aacMedium, .aacLow: "aac"
        case .opusHigh, .opusMedium, .opusLow: "opus"
        case .mp3High, .mp3Medium, .mp3Low: "mp3"
        }
    }

    /// The `maxBitRate` parameter in kbps; nil for Original.
    public var maxBitRate: Int? {
        switch self {
        case .original: nil
        case .aacHigh: 256
        case .aacMedium: 160
        case .aacLow: 96
        case .opusHigh: 320
        case .opusMedium: 160
        case .opusLow: 96
        case .mp3High: 320
        case .mp3Medium: 192
        case .mp3Low: 128
        }
    }

    /// nil for Original.
    public var level: QualityLevel? {
        switch self {
        case .original: nil
        case .aacHigh, .opusHigh, .mp3High: .high
        case .aacMedium, .opusMedium, .mp3Medium: .medium
        case .aacLow, .opusLow, .mp3Low: .low
        }
    }

    /// A picker row under its format's heading: "High · 320 kbps", or "Original".
    public var title: String {
        guard let level, let maxBitRate else { return "Original" }
        return "\(level.title) · \(maxBitRate) kbps"
    }

    /// The format and bit rate on their own line (a summary, a picker's value): "AAC 256 kbps", or "Original".
    public var shortTitle: String {
        guard let maxBitRate else { return "Original" }
        return "\(Self.formatName(format)) \(maxBitRate) kbps"
    }

    /// "AAC", "Opus", "MP3"; "Original" for the untouched file.
    public static func formatName(_ format: String) -> String {
        switch format {
        case "raw": "Original"
        case "aac": "AAC"
        case "opus": "Opus"
        case "mp3": "MP3"
        default: format.uppercased()
        }
    }

    /// The qualities by codec, in enum order: what the pickers list under each codec heading.
    public static var groups: [(format: String, qualities: [StreamQuality])] {
        var result: [(format: String, qualities: [StreamQuality])] = []
        for quality in allCases {
            if let i = result.firstIndex(where: { $0.format == quality.format }) { result[i].qualities.append(quality) }
            else { result.append((quality.format, [quality])) }
        }
        return result
    }

    /// The highest bit rate a stored name is read as; anything above is not a saved setting.
    static let migrationCeiling = 640

    /// A stored name: a preset's own, or an older bit rate ("opus128", "mp3_256") moved to the nearest preset of its
    /// format, a tie going up. nil for anything else.
    public init?(migrating stored: String) {
        if let exact = StreamQuality(rawValue: stored) {
            self = exact
            return
        }
        guard let format = ["aac", "opus", "mp3"].first(where: { stored.hasPrefix($0) }) else { return nil }
        var digits = stored.dropFirst(format.count)
        if digits.first == "_" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), digits.count <= 4,
              let rate = Int(digits), (1...Self.migrationCeiling).contains(rate) else { return nil }
        let presets = Self.allCases.filter { $0.format == format && $0.maxBitRate != nil }
        guard let nearest = presets.min(by: { a, b in
            let da = abs(a.maxBitRate! - rate), db = abs(b.maxBitRate! - rate)
            return da != db ? da < db : a.maxBitRate! > b.maxBitRate!   // a tie goes up
        }) else { return nil }
        self = nearest
    }
}

extension StreamQuality: Codable {
    /// Reads a preset's name or an older bit rate (`init(migrating:)`); anything else fails, so the preference area's
    /// lossy decode puts its default back.
    public init(from decoder: Decoder) throws {
        let stored = try decoder.singleValueContainer().decode(String.self)
        guard let quality = StreamQuality(migrating: stored) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown quality"))
        }
        self = quality
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
