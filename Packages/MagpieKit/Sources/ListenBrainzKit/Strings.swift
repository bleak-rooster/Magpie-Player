import Foundation

extension String {
    /// Remote text is untrusted: trimmed and capped at 500 characters.
    var capped: String { String(trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) }
}

/// Decodes an array, silently dropping elements that fail to decode.
struct LossyArray<T: Decodable>: Decodable {
    var values: [T]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [T] = []
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) { out.append(value) } else { _ = try? container.decode(Skip.self) }
        }
        values = out
    }

    private struct Skip: Decodable {}
}
