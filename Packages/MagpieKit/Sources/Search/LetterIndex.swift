import Foundation

/// The A–Z + "#" index of a list (priority round P2): which letter a name files under, the list's runs of one letter,
/// where a tapped letter goes, and (for lists the server pages) the first offset of a letter.
///
/// A name files under its first character, folded case- and diacritic-insensitively ("Àlbum" under A, "Œuvre" under O).
/// Digits, symbols, emoji, an empty name and other scripts ("おやすみ") file under "#". Leading articles count unless
/// the caller passes the articles its list's sort drops: Navidrome sorts song titles with them ("The Cat" under T) but
/// artists and albums without its default articles (`navidromeArticles`), verified on the dev stack.
public enum LetterIndex {
    /// "#", then A to Z: the index as shown.
    public static let letters: [String] = ["#"] + (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(UnicodeScalar($0)) }

    /// Navidrome's default `IgnoredArticles`, dropped from artist and album names when it sorts them.
    public static let navidromeArticles = ["The", "El", "La", "Los", "Las", "Le", "Les", "Os", "As", "O", "A"]

    /// The letter `name` files under: "A"…"Z" or "#".
    public static func key(_ name: String, ignoringArticles articles: [String] = []) -> String {
        guard let scalar = firstFolded(name, articles), let i = letterIndex(scalar) else { return "#" }
        return letters[i]
    }

    /// `name` without a leading article from `articles` (a whole word followed by a space, never the whole name).
    public static func sortName(_ name: String, ignoringArticles articles: [String]) -> Substring {
        let trimmed = name.drop(while: \.isWhitespace)
        for article in articles {
            guard trimmed.count > article.count + 1,
                  trimmed.prefix(article.count).compare(article, options: .caseInsensitive) == .orderedSame,
                  let after = trimmed.dropFirst(article.count).first, after == " " else { continue }
            return trimmed.dropFirst(article.count).drop(while: \.isWhitespace)
        }
        return trimmed
    }

    /// One run of neighbouring items under the same letter.
    public struct Section: Sendable, Hashable {
        public var key: String
        /// The items' positions in the list.
        public var range: Range<Int>
        /// False when an earlier run has the same key (other scripts file under "#" but sort after Z): only the first
        /// run of a key is the index's target and carries its label.
        public var isFirstOfKey: Bool
    }

    /// The list's runs of one letter, in list order. Linear; one fold per item.
    public static func sections<Item>(_ items: [Item], ignoringArticles articles: [String] = [],
                                      name: (Item) -> String) -> [Section] {
        var out: [Section] = []
        var seen = Set<String>()
        for (i, item) in items.enumerated() {
            let k = key(name(item), ignoringArticles: articles)
            if let last = out.last, last.key == k {
                out[out.count - 1].range = last.range.lowerBound..<(i + 1)
            } else {
                out.append(Section(key: k, range: i..<(i + 1), isFirstOfKey: seen.insert(k).inserted))
            }
        }
        return out
    }

    /// Where tapping `letter` goes: the first run of that letter; else the first run of the nearest letter after it;
    /// else the nearest before it. Works on unsorted lists too (the curated genre groups).
    public static func target(_ letter: String, in sections: [Section]) -> Section? {
        guard let wanted = letters.firstIndex(of: letter) else { return nil }
        let firsts = sections.filter(\.isFirstOfKey)
        if let exact = firsts.first(where: { $0.key == letter }) { return exact }
        let rank = { (s: Section) in letters.firstIndex(of: s.key) ?? 0 }
        if let after = firsts.filter({ rank($0) > wanted }).min(by: { rank($0) < rank($1) }) { return after }
        return firsts.filter { rank($0) < wanted }.max { rank($0) < rank($1) }
    }

    /// The first offset of a server-paged list (sorted by the server) whose name files at or after `letter`, by
    /// binary search over single-item reads (`nameAt` gives nil past the end). Without `total` it gallops first.
    /// At most about 2·log2(count) reads; `maxProbes` bounds it. Returns the list's end when every name sorts before
    /// the letter.
    ///
    /// The server sorts on folded names: "#" names below "a" (digits, most symbols) come first, other scripts and
    /// emoji after "z". Those rank 0 and 27 here so the order stays monotone.
    public static func seek(_ letter: String, total: Int?, ignoringArticles articles: [String] = [],
                            maxProbes: Int = 64, nameAt: @Sendable (Int) async throws -> String?) async throws -> Int {
        try await seek(rank: letters.firstIndex(of: letter) ?? 0, total: total, ignoringArticles: articles,
                       maxProbes: maxProbes, nameAt: nameAt)
    }

    /// Round 13: the first offset whose name sorts after "z" (other scripts, emoji; `rank` 27), as `seek` finds a
    /// letter's: the car's "#" songs that come last in the server's order.
    public static func seekPastZ(total: Int?, maxProbes: Int = 64,
                                 nameAt: @Sendable (Int) async throws -> String?) async throws -> Int {
        try await seek(rank: 27, total: total, ignoringArticles: [], maxProbes: maxProbes, nameAt: nameAt)
    }

    private static func seek(rank wanted: Int, total: Int?, ignoringArticles articles: [String],
                             maxProbes: Int, nameAt: @Sendable (Int) async throws -> String?) async throws -> Int {
        guard wanted > 0 else { return 0 }
        var probes = 0
        func reaches(_ offset: Int) async throws -> Bool {
            try Task.checkCancellation()   // the screen went away: stop reading
            probes += 1
            guard let name = try await nameAt(offset) else { return true }   // past the end
            return rank(name, articles) >= wanted
        }
        var lo = 0, hi: Int
        if let total {
            hi = max(total, 0)
        } else {
            if try await reaches(0) { return 0 }
            var probe = 1
            while try await !reaches(probe) {
                lo = probe + 1
                guard probes < maxProbes / 2, probe < Int.max / 4 else { return lo }
                probe *= 2
            }
            hi = probe
        }
        while lo < hi, probes < maxProbes {
            let mid = lo + (hi - lo) / 2
            if try await reaches(mid) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    // MARK: - Server-paged lists

    /// Where `letter` is among the items loaded so far, without asking the server; nil when only the server can say.
    /// `windowStart`: the server offset of the first loaded item (a jump far ahead loads from there, so the run it
    /// starts in may have begun earlier and isn't trusted). `complete`: everything from `windowStart` to the end is
    /// loaded, so a missing letter goes to the nearest one.
    public static func loadedTarget(_ letter: String, sections: [Section], windowStart: Int, complete: Bool) -> Int? {
        if windowStart > 0 {
            return sections.first { $0.key == letter && $0.isFirstOfKey && $0.range.lowerBound > 0 }?.range.lowerBound
        }
        if let exact = sections.first(where: { $0.key == letter && $0.isFirstOfKey }) { return exact.range.lowerBound }
        return complete ? target(letter, in: sections)?.range.lowerBound : nil
    }

    /// How a paged list reaches the server offset a seek found.
    public enum WindowMove: Sendable, Equatable {
        /// Loaded already: this many items into the window.
        case scroll(Int)
        /// A few pages ahead: read on until the offset is loaded.
        case pageForward(untilOffset: Int)
        /// Far ahead, or before the window: load from the offset instead.
        case restart(at: Int)
    }

    /// `windowStart..<windowEnd`: the server offsets loaded. Ahead by at most `forwardLimit`: page forward.
    public static func move(toOffset offset: Int, windowStart: Int, windowEnd: Int, forwardLimit: Int) -> WindowMove {
        let offset = max(offset, 0)
        if offset < windowStart { return .restart(at: offset) }
        if offset < windowEnd { return .scroll(offset - windowStart) }
        return offset - windowEnd <= forwardLimit ? .pageForward(untilOffset: offset) : .restart(at: offset)
    }

    // MARK: - Folding

    /// 0: files under "#" and sorts before "a"; 1–26: A–Z; 27: other scripts, emoji and symbols after "z". Round 13:
    /// public, so the car can put the phone's songs in the server's order offline.
    public static func rank(_ name: String, _ articles: [String] = []) -> Int {
        guard let scalar = firstFolded(name, articles) else { return 0 }
        if let i = letterIndex(scalar) { return i }
        return scalar.value < 0x61 ? 0 : 27
    }

    private static func letterIndex(_ s: Unicode.Scalar) -> Int? {
        (0x61...0x7A).contains(s.value) ? Int(s.value - 0x61) + 1 : nil
    }

    /// Letters that don't decompose, so diacritic folding leaves them: folded by hand, as Navidrome's sort does.
    private static let ligatures: [Character: Unicode.Scalar] = [
        "œ": "o", "Œ": "o", "æ": "a", "Æ": "a", "ø": "o", "Ø": "o", "ß": "s", "ẞ": "s", "ł": "l", "Ł": "l",
        "đ": "d", "Đ": "d", "þ": "t", "Þ": "t", "ð": "d", "Ð": "d", "ı": "i",
    ]

    /// The first character of the (article-free) name, folded to one scalar. Nil for an empty or blank name.
    private static func firstFolded(_ name: String, _ articles: [String]) -> Unicode.Scalar? {
        let base = articles.isEmpty ? name.drop(while: \.isWhitespace) : sortName(name, ignoringArticles: articles)
        guard let first = base.first else { return nil }
        if let mapped = ligatures[first] { return mapped }
        return String(first).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.first
    }
}
