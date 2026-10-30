import Foundation

/// How deeply a JSON document nests, measured without parsing it (crash hunt 4). `JSONSerialization` recurses once
/// per nested object with no limit of its own, and about 500 levels overflow the 512 KB stack of a Swift concurrency
/// thread (SIGBUS), so untrusted bytes are measured before it reads them.
public enum JSONNesting {
    /// Deeper than any document Magpie reads or stores (the Lidarr write gate refuses past the same depth).
    public static let limit = 64

    /// Whether no array or object in `data` opens more than `limit` levels deep. Brackets inside strings don't count.
    public static func isWithin(_ data: Data, limit: Int = JSONNesting.limit) -> Bool {
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > limit { return false }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return true
    }

    /// `JSONSerialization.jsonObject(with:)` for untrusted bytes: nil when the document nests past `limit` or isn't JSON.
    public static func object(with data: Data, options: JSONSerialization.ReadingOptions = [], limit: Int = JSONNesting.limit) -> Any? {
        guard isWithin(data, limit: limit) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: options)
    }
}
