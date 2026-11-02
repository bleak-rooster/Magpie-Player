import Foundation

/// The library queries for one search (round 12, plan item 1): the whole query, plus at most four *splits* that each
/// search a title part and keep only the songs and albums whose artist matches the other part. Navidrome needs every
/// word of a query to match, so "hey jude beatels" finds nothing whole, but "hey jude" by an artist like "beatels"
/// does.
///
/// - "title - artist" (or " – ", " — "; a dash needs spaces round it, so "a–ha" stays whole) parses into both orders, and "title by artist" into one, with no guessing.
/// - Otherwise each split tries one word boundary near an end, in both orders: the artist as the last word, the first
///   word, the last two words, then the first two. A part that is only an article is skipped.
public struct SearchPlan: Equatable, Sendable {
    public struct Split: Equatable, Sendable, Hashable {
        public var title: String
        public var artist: String
    }

    public static let maxSplits = 4

    /// What the whole query searches (a dash separator is dropped, since Navidrome ignores it anyway).
    public var whole: String
    public var splits: [Split]

    public init(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        whole = q
        splits = []
        if let (left, right) = Self.cut(q, at: [" - ", " – ", " — "]) {
            whole = left + " " + right
            splits = [Split(title: left, artist: right), Split(title: right, artist: left)]
        } else if let (left, right) = Self.cut(q, at: [" by "], caseInsensitive: true) {
            splits = [Split(title: left, artist: right)]
        } else {
            splits = Self.wordSplits(q)
        }
    }

    /// The text either side of the first separator found, when both sides have a word.
    private static func cut(_ q: String, at separators: [String], caseInsensitive: Bool = false) -> (String, String)? {
        for sep in separators {
            guard let r = q.range(of: sep, options: caseInsensitive ? [.caseInsensitive] : []) else { continue }
            let left = q[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = q[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard hasWord(left), hasWord(right) else { return nil }
            return (left, right)
        }
        return nil
    }

    private static func hasWord(_ s: String) -> Bool { s.contains { $0.isLetter || $0.isNumber } }

    private static func wordSplits(_ q: String) -> [Split] {
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init).filter(hasWord)
        guard words.count >= 2 else { return [] }
        var out: [Split] = []
        for k in 1...2 where k < words.count {
            let head = words.prefix(words.count - k).joined(separator: " "), tail = words.suffix(k).joined(separator: " ")
            let lead = words.prefix(k).joined(separator: " "), rest = words.dropFirst(k).joined(separator: " ")
            for split in [Split(title: head, artist: tail), Split(title: rest, artist: lead)]
                where !isArticle(split.title) && !isArticle(split.artist) && !out.contains(split) {
                out.append(split)
            }
        }
        return Array(out.prefix(maxSplits))
    }

    private static func isArticle(_ part: String) -> Bool {
        SearchRanker.chunks(part).allSatisfy { SearchRanker.articles.contains($0.joined) }
    }
}
