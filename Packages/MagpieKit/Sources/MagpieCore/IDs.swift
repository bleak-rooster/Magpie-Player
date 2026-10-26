import Foundation

/// A MusicBrainz identifier: always a lower-cased UUID string.
public struct MBID: Sendable, Hashable, Codable {
    public let rawValue: String

    public init?(_ s: String) {
        guard let uuid = UUID(uuidString: s) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let mbid = MBID(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not a valid MBID: \(s)"))
        }
        self = mbid
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
