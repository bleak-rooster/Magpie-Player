import Foundation

/// Text normalisation for matching library songs to songs from elsewhere (match ladder, Task 4.3).
public enum Normalize {
    /// `artist` and `title`, normalised and joined. Equal keys mean "same song, by name".
    public static func key(artist: String, title: String) -> String {
        name(artist) + "\u{1F}" + name(title)
    }

    /// One name, normalised: lower-cased, accents and widths folded, "feat." credits and bracketed
    /// asides like "(Remastered 2011)" removed, punctuation dropped, spaces collapsed. CJK and other
    /// letters are kept as they are. A name that is nothing but an aside keeps the aside's words.
    public static func name(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                               locale: Locale(identifier: "en_US_POSIX"))
        let stripped = words(removingFeat(removingRemasterSuffix(removingBrackets(folded))))
        return stripped.isEmpty ? words(folded) : stripped
    }

    // MARK: - Steps

    private static let openers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "（": "）", "【": "】"]

    /// Drops every bracketed aside, including nested ones. An unclosed bracket drops the rest.
    private static func removingBrackets(_ s: String) -> String {
        var out = ""
        var closers: [Character] = []
        for c in s {
            if let close = openers[c] {
                closers.append(close)
            } else if let last = closers.last, c == last {
                closers.removeLast()
                out.append(" ")
            } else if closers.isEmpty {
                out.append(c)
            }
        }
        return out
    }

    /// "Halo - Remastered 2011" → "Halo". Only remaster asides; " - Live" or " - Remix" are other recordings.
    private static func removingRemasterSuffix(_ s: String) -> String {
        for dash in [" - ", " – ", " — "] {
            if let r = s.range(of: dash, options: .backwards),
               s[r.upperBound...].contains("remaster") {
                return String(s[..<r.lowerBound])
            }
        }
        return s
    }

    /// Cuts at the first "feat." / "ft." / "featuring" word: "Song feat. X" → "Song".
    private static func removingFeat(_ s: String) -> String {
        let markers: Set<String> = ["feat", "feat.", "ft", "ft.", "featuring"]
        var kept: [Substring] = []
        for word in s.split(whereSeparator: \.isWhitespace) {
            if markers.contains(String(word)) { break }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    /// Punctuation and symbols become spaces; runs of spaces collapse to one.
    private static func words(_ s: String) -> String {
        let scalars = s.unicodeScalars.map { u -> Character in
            CharacterSet.punctuationCharacters.contains(u) || CharacterSet.symbols.contains(u) ? " " : Character(u)
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
