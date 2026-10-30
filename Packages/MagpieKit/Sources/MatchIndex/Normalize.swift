import Foundation

/// Text normalisation for matching library songs to songs from elsewhere (match ladder, Task 4.3).
public enum Normalize {
    /// Words that make a different recording of the same song. They stay in the key, so "Halo (Live)"
    /// and "Halo" never match by name.
    public static let versionWords: Set<String> = [
        "live", "acoustic", "remix", "demo", "instrumental", "unplugged", "karaoke", "edit", "mix", "version",
    ]

    /// Housekeeping asides that name the same recording, stripped like "(Remastered 2011)" even
    /// though they contain a version word. Matched as a whole phrase after punctuation is dropped
    /// (so `7" Version` is "7 version").
    public static let sameRecordingPhrases: Set<String> = [
        "album version", "single version", "radio edit", "radio version", "original mix", "original version",
        "explicit version", "clean version", "mono version", "stereo version", "lp version", "7 version",
        "12 version", "edit version",
    ]

    /// `artist` and `title`, normalised and joined. Equal keys mean "same song, by name".
    public static func key(artist: String, title: String) -> String {
        name(artist) + "\u{1F}" + name(title)
    }

    /// One name, normalised: lower-cased, accents and widths folded, featured-artist credits and
    /// bracketed asides like "(Remastered 2011)" or "[Explicit]" removed, punctuation dropped, spaces
    /// collapsed. Version words in an aside are kept ("Halo [Live]" → "halo live"). CJK and other
    /// letters are kept as they are. A name that is nothing but an aside keeps the aside's words.
    public static func name(_ s: String) -> String {
        let folded = fold(s)
        let stripped = words(removingFeat(removingDashSuffix(removingAsides(folded))))
        return stripped.isEmpty ? words(folded) : stripped
    }

    /// Whether the title marks itself as another version: a version word in a bracketed aside or
    /// after " - " ("Halo (Live)", "Halo - Acoustic"). Such a title is never treated as a library
    /// song on a name-only match.
    public static func hasVersionAside(_ title: String) -> Bool {
        let folded = fold(title)
        let asides = bracketed(folded).map(\.aside) + (dashSplit(folded).map { [String($0.suffix)] } ?? [])
        return asides.contains { !versionWordsIn($0).isEmpty }   // housekeeping asides yield none
    }

    // MARK: - Steps

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
    }

    private static let openers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "（": "）", "【": "】"]

    /// The text outside brackets, and each top-level aside's text. An unclosed bracket runs to the end.
    private static func bracketed(_ s: String) -> [(outside: String, aside: String)] {
        var parts: [(String, String)] = []
        var outside = "", aside = ""
        var closers: [Character] = []
        for c in s {
            if let close = openers[c] {
                if !closers.isEmpty { aside.append(" ") }
                closers.append(close)
            } else if let last = closers.last, c == last {
                closers.removeLast()
                if closers.isEmpty { parts.append((outside, aside)); outside = ""; aside = "" } else { aside.append(" ") }
            } else if closers.isEmpty {
                outside.append(c)
            } else {
                aside.append(c)
            }
        }
        parts.append((outside, aside))
        return parts
    }

    /// Drops every bracketed aside but keeps its version words: "halo [live] (feat. x)" → "halo live".
    private static func removingAsides(_ s: String) -> String {
        bracketed(s).map { part in
            let kept = isFeatClause(part.aside) ? [] : versionWordsIn(part.aside)
            return part.outside + " " + kept.joined(separator: " ") + " "
        }.joined()
    }

    /// The text before and after the last " - " (or en/em dash), if any.
    private static func dashSplit(_ s: String) -> (head: Substring, suffix: Substring)? {
        for dash in [" - ", " – ", " — "] {
            if let r = lastRange(of: dash, in: s) { return (s[..<r.lowerBound], s[r.upperBound...]) }
        }
        return nil
    }

    /// The last occurrence of `separator` in `s`, found by searching forwards from each match (overlapping ones too).
    /// Stands in for `range(of:options: .backwards)`, which is quadratic on a run of flag emoji (regional indicators):
    /// 20,000 flags took seconds, on the main actor in the car's "Try it next" (crash hunt 4, watchdog).
    public static func lastRange(of separator: String, in s: String) -> Range<String.Index>? {
        var found: Range<String.Index>?
        var from = s.startIndex
        while from < s.endIndex, let r = s.range(of: separator, range: from..<s.endIndex) {
            found = r
            from = s.index(after: r.lowerBound)
        }
        return found
    }

    /// "halo - remastered 2011" → "halo"; "halo - feat. x" → "halo"; "halo - live" stays (another
    /// recording); other suffixes stay too (they may be part of the title).
    private static func removingDashSuffix(_ s: String) -> String {
        guard let (head, suffix) = dashSplit(s) else { return s }
        let text = String(suffix)
        let strip = sameRecordingPhrases.contains(words(text))
            || (versionWordsIn(text).isEmpty && (text.contains("remaster") || isFeatClause(text)))
        guard strip else { return s }
        return String(head)
    }

    /// A featured-artist clause: starts with "feat", "feat.", "ft", "ft." or "featuring".
    private static func isFeatClause(_ s: String) -> Bool {
        guard let first = s.split(whereSeparator: \.isWhitespace).first else { return false }
        return ["feat", "ft", "featuring"].contains(first) || first.hasPrefix("feat.") || first.hasPrefix("ft.")
    }

    /// Cuts an unbracketed credit: "song feat. x", "song ft. x", "song feat.x", "song featuring x" →
    /// "song". Needs the dot for feat/ft so "six ft under" stays whole, and never cuts at the first word.
    private static func removingFeat(_ s: String) -> String {
        let all = s.split(whereSeparator: \.isWhitespace)
        var kept: [Substring] = []
        for (i, word) in all.enumerated() {
            if i > 0, word == "featuring" || word.hasPrefix("feat.") || word.hasPrefix("ft.") { break }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    /// The version words an aside keeps. None for a housekeeping phrase ("Radio Edit"); a bare
    /// "version" next to another version word is dropped ("Acoustic Version" → "acoustic").
    private static func versionWordsIn(_ s: String) -> [String] {
        let text = words(s)
        guard !sameRecordingPhrases.contains(text) else { return [] }
        let found = text.split(separator: " ").map(String.init).filter { versionWords.contains($0) }
        return found.count > 1 ? found.filter { $0 != "version" } : found
    }

    /// Punctuation and symbols become spaces; runs of spaces collapse to one.
    private static func words(_ s: String) -> String {
        let scalars = s.unicodeScalars.map { u -> Character in
            CharacterSet.punctuationCharacters.contains(u) || CharacterSet.symbols.contains(u) ? " " : Character(u)
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
