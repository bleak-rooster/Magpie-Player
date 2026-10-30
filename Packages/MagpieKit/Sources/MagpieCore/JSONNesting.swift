import Foundation

/// How deeply a JSON document nests, measured without parsing it (crash hunt 4). `JSONSerialization` recurses once
/// per nested object with no limit of its own, and about 500 levels overflow the 512 KB stack of a Swift concurrency
/// thread (SIGBUS), so untrusted bytes are measured before it reads them.
public enum JSONNesting {
    /// Deeper than any document Magpie reads or stores (the Lidarr write gate refuses past the same depth).
    public static let limit = 64

    /// Whether no array or object in `data` opens more than `limit` levels deep. Brackets inside strings don't count.
    /// False for anything that can't be measured: a stray closer, or bytes that aren't JSON in UTF-8, UTF-16 or UTF-32.
    public static func isWithin(_ data: Data, limit: Int = JSONNesting.limit) -> Bool {
        guard let utf8 = utf8(data) else { return false }
        return isWithin(utf8: utf8, limit: limit)
    }

    /// `JSONSerialization.jsonObject(with:)` for untrusted bytes: nil when the document nests past `limit` or isn't JSON.
    /// The parser reads the same UTF-8 bytes that were measured, so the two can't disagree about the encoding.
    public static func object(with data: Data, options: JSONSerialization.ReadingOptions = [], limit: Int = JSONNesting.limit) -> Any? {
        guard let utf8 = utf8(data), isWithin(utf8: utf8, limit: limit) else { return nil }
        return try? JSONSerialization.jsonObject(with: utf8, options: options)
    }

    /// Scans UTF-8 bytes. A NUL byte refuses the document: JSON in UTF-8 has none (a control character in a string
    /// must be escaped), while UTF-16 and UTF-32 have one beside every ASCII character, so a body whose encoding was
    /// misjudged is refused rather than measured wrongly (merged crash-hunt review, I2: "Ģ" in UTF-16LE is `22 01`,
    /// and its `22` read as a quote hid every bracket after it).
    private static func isWithin(utf8 data: Data, limit: Int) -> Bool {
        data.withUnsafeBytes { bytes in
            var depth = 0, inString = false, escaped = false
            for byte in bytes {
                if byte == 0 { return false }
                if inString {
                    if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                    continue
                }
                switch byte {
                case 0x22: inString = true                                  // "
                case 0x5B, 0x7B:                                            // [ {
                    depth += 1
                    if depth > limit { return false }
                case 0x5D, 0x7D:                                            // ] }
                    if depth == 0 { return false }                          // a stray closer: not JSON
                    depth -= 1
                default: break
                }
            }
            return true
        }
    }

    /// `data` as UTF-8 without a BOM, nil when it doesn't decode. The encoding is judged the way `JSONSerialization`
    /// judges it (RFC 4627 §3): a BOM, else the pattern of zero bytes among the first four (a JSON text starts with
    /// two ASCII characters).
    static func utf8(_ data: Data) -> Data? {
        let head = Array(data.prefix(4)) + [UInt8](repeating: 0xAA, count: max(0, 4 - data.count))
        let (encoding, bom): (String.Encoding, Int)
        switch (head[0], head[1], head[2], head[3]) {
        case (0xEF, 0xBB, 0xBF, _): (encoding, bom) = (.utf8, 3)
        case (0x00, 0x00, 0xFE, 0xFF): (encoding, bom) = (.utf32BigEndian, 4)
        case (0xFF, 0xFE, 0x00, 0x00): (encoding, bom) = (.utf32LittleEndian, 4)
        case (0xFE, 0xFF, _, _): (encoding, bom) = (.utf16BigEndian, 2)
        case (0xFF, 0xFE, _, _): (encoding, bom) = (.utf16LittleEndian, 2)
        case (0x00, 0x00, 0x00, _) where data.count >= 4: (encoding, bom) = (.utf32BigEndian, 0)
        case (_, 0x00, 0x00, 0x00) where data.count >= 4: (encoding, bom) = (.utf32LittleEndian, 0)
        case (0x00, _, _, _) where data.count >= 2: (encoding, bom) = (.utf16BigEndian, 0)
        case (_, 0x00, _, _) where data.count >= 2: (encoding, bom) = (.utf16LittleEndian, 0)
        default: return data
        }
        let body = data.dropFirst(bom)
        if encoding == .utf8 { return Data(body) }
        let unit = encoding == .utf16BigEndian || encoding == .utf16LittleEndian ? 2 : 4
        guard body.count % unit == 0, let text = String(data: Data(body), encoding: encoding) else { return nil }
        return Data(text.utf8)
    }
}
