import Foundation
import MagpieCore

/// Field-aware ranking for search (round 12, plan item 1). A hit scores by how many query words it covers across its
/// title, artist and album, whole words above prefixes above near-misses (typos), with case, accents and widths
/// folded. Leading articles ("the", "a", "le", ...) are optional in the query and in names. The same score orders
/// every section, picks the Top result and orders the outside rows. Pure; no I/O.
public enum SearchRanker {
    /// Words that don't have to match: "the national" finds "National", "national" finds "The National".
    static let articles: Set<String> = ["the", "a", "an", "le", "la", "les", "l", "el", "los", "las", "die", "der", "das"]

    // MARK: - Query

    /// A query, folded and split into words once.
    public struct Query: Sendable, Equatable {
        public let text: String
        /// Every word must match for a hit to cover the query.
        let required: [String]
        /// Articles: a match only adds a little.
        let optional: [String]

        public init(_ text: String) {
            self.text = text
            let words = SearchRanker.chunks(text).map(\.joined).filter { !$0.isEmpty }
            let plain = words.filter { !SearchRanker.articles.contains($0) }
            if plain.isEmpty {   // "the the": nothing but articles, so they count
                required = words; optional = []
            } else {
                required = plain; optional = words.filter { SearchRanker.articles.contains($0) }
            }
        }

        public var isEmpty: Bool { required.isEmpty }
    }

    // MARK: - Score

    /// How well a hit matches. Compared in order: words covered, whether the main name (song title, album or artist
    /// name) is matched in full, how many of the name and artist fields are matched in full, then match quality.
    public struct Score: Comparable, Sendable {
        public var covered = 0
        public var primaryFull = false
        public var fullFields = 0
        public var quality = 0
        /// The words covered the title (or name) and the artist both (plan item 1.3).
        public var usesTitleAndArtist = false

        public static func < (a: Score, b: Score) -> Bool {
            (a.covered, a.primaryFull ? 1 : 0, a.fullFields, a.quality) < (b.covered, b.primaryFull ? 1 : 0, b.fullFields, b.quality)
        }
    }

    public static func score(_ song: Song, _ q: Query) -> Score {
        score([Field(song.title, .primary), Field(song.artist, .artist), Field(song.album, .other)], q)
    }

    public static func score(_ album: Album, _ q: Query) -> Score {
        score([Field(album.name, .primary), Field(album.artist, .artist)], q)
    }

    public static func score(_ artist: Artist, _ q: Query) -> Score {
        score([Field(artist.name, .primary)], q)
    }

    public static func score(recording: ExternalRecording, _ q: Query) -> Score {
        score([Field(recording.title, .primary), Field(recording.artist, .artist), Field(recording.releaseTitle ?? "", .other)], q)
    }

    public static func score(notYetAlbum a: NotYetAlbum, _ q: Query) -> Score {
        score([Field(a.title, .primary), Field(a.artist, .artist)], q)
    }

    public static func score(notYetArtist a: NotYetArtist, _ q: Query) -> Score {
        score([Field(a.name, .primary)], q)
    }

    /// Best first; equal scores keep their order (the server's or the source's).
    public static func rank<T>(_ items: [T], _ q: Query, _ score: (T, Query) -> Score) -> [T] {
        guard !q.isEmpty, items.count > 1 else { return items }
        return items.enumerated()
            .map { (offset: $0.offset, item: $0.element, score: score($0.element, q)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.item)
    }

    /// The Top result: the best-scoring hit of any kind. On a tie an artist comes before an album, an album before a
    /// song, and then the server's order.
    public static func top(songs: [Song], albums: [Album], artists: [Artist], _ q: Query) -> SearchItem? {
        var best: (item: SearchItem, score: Score)?
        func consider(_ item: SearchItem, _ s: Score) {
            if best == nil || s > best!.score { best = (item, s) }   // strictly better: earlier kinds and rows win ties
        }
        artists.forEach { consider(.artist($0), score($0, q)) }
        albums.forEach { consider(.album($0), score($0, q)) }
        songs.forEach { consider(.song($0), score($0, q)) }
        if let best, best.score.covered > 0 { return best.item }
        // Nothing covers a word (the server matched a field we don't see): its first song, else artist, else album.
        return songs.first.map(SearchItem.song) ?? artists.first.map(SearchItem.artist) ?? albums.first.map(SearchItem.album)
    }

    /// Whether every word of `part` matches a word of `name` (whole, prefix or near-miss): a split query keeps only
    /// the songs and albums whose artist is the other part.
    ///
    /// - Parameter strict: near-misses only for words of 6 letters or more, so a split's artist "love" doesn't keep
    ///   "Live" (fix round 1, review M1).
    public static func nameMatches(_ name: String, _ part: String, strict: Bool = false) -> Bool {
        let q = Query(part)
        guard !q.isEmpty else { return false }
        let field = Field(name, .primary)
        return q.required.allSatisfy { w in
            let m = match(w, field)
            return m >= 2 || (m == 1 && (!strict || w.count >= 6))
        }
    }

    // MARK: - Fields

    enum Role { case primary, artist, other }

    /// One whitespace-separated piece of a name, folded: its punctuation-free form ("ac/dc" → "acdc") and its parts
    /// ("ac", "dc").
    struct Chunk {
        let joined: String
        let parts: [String]
        var variants: [String] { parts.count > 1 ? [joined] + parts : [joined] }
    }

    struct Field {
        let role: Role
        let chunks: [Chunk]
        /// The folded text, for words in scripts written without spaces.
        let text: String

        init(_ s: String, _ role: Role) {
            self.role = role
            chunks = SearchRanker.chunks(s).filter { !$0.joined.isEmpty }
            text = chunks.map(\.joined).joined(separator: " ")
        }

        /// The chunks that must all match for the field to count as matched in full (articles don't, unless the
        /// name is nothing else).
        var significant: [Chunk] {
            let plain = chunks.filter { !SearchRanker.articles.contains($0.joined) }
            return plain.isEmpty ? chunks : plain
        }
    }

    static func fold(_ s: String) -> String {
        var out = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                            locale: Locale(identifier: "en_US_POSIX"))
        for (from, to) in [("œ", "oe"), ("æ", "ae"), ("ß", "ss"), ("ø", "o"), ("đ", "d"), ("ł", "l"), ("þ", "th"),
                           ("’", "'")] where out.contains(from) {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }

    static func chunks(_ s: String) -> [Chunk] {
        fold(s).split(whereSeparator: \.isWhitespace).map { raw in
            let parts = raw.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
            return Chunk(joined: parts.joined(), parts: parts)
        }
    }

    /// Hiragana, katakana, CJK, Hangul, Thai and the like: written without spaces, so a word matches anywhere.
    static func isUnspaced(_ w: String) -> Bool {
        w.unicodeScalars.contains { s in
            switch s.value {
            case 0x0E00...0x0EFF, 0x1000...0x109F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
            default: false
            }
        }
    }

    // MARK: - Matching

    /// 3 for a whole word, 2 for a prefix (or a word inside unspaced text), 1 for a near-miss, 0 for none.
    static func match(_ w: String, _ field: Field) -> Int {
        if isUnspaced(w) {
            if field.chunks.contains(where: { $0.joined == w }) { return 3 }
            return field.text.contains(w) ? 2 : 0
        }
        var best = 0
        for chunk in field.chunks {
            for v in chunk.variants {
                if v == w { return 3 }
                if v.hasPrefix(w) { best = max(best, 2) } else if best == 0, isNearMiss(w, v) { best = 1 }
            }
        }
        return best
    }

    /// Whether a chunk counts as matched in full: some query word is it (or a near-miss of it).
    static func covers(_ words: [String], _ chunk: Chunk) -> Bool {
        words.contains { w in
            chunk.variants.contains { v in v == w || (!isUnspaced(w) && v.count >= 4 && isNearMiss(w, v, prefix: false)) }
        }
    }

    /// One edit (two for long words) away, as a whole word or as the start of a longer one. Short words never are.
    static func isNearMiss(_ w: String, _ v: String, prefix: Bool = true) -> Bool {
        guard w.count >= 4 else { return false }
        let limit = w.count >= 8 ? 2 : 1
        if abs(w.count - v.count) <= limit, distance(Array(w), Array(v), limit: limit) <= limit { return true }
        guard prefix, v.count > w.count + limit else { return false }
        return distance(Array(w), Array(v.prefix(w.count)), limit: limit) <= limit
    }

    /// Optimal string alignment distance (Damerau–Levenshtein with adjacent swaps), stopping early past `limit`.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if a == b { return 0 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { cur[j] = min(cur[j], prev2[j - 2] + 1) }
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[b.count]
    }

    static func score(_ fields: [Field], _ q: Query) -> Score {
        var s = Score()
        guard !q.isEmpty else { return s }
        var usedPrimary = false, usedArtist = false
        for w in q.required {
            // The best field for this word; the earlier field (the name) wins a tie.
            var best = 0, bestWeighted = 0, bestRole = Role.other
            for f in fields {
                let m = match(w, f)
                let weighted = f.role == .primary ? m * 2 : m
                if weighted > bestWeighted { best = m; bestWeighted = weighted; bestRole = f.role }
            }
            guard best > 0 else { continue }
            s.covered += 1
            s.quality += bestWeighted
            if bestRole == .primary { usedPrimary = true }
            if bestRole == .artist { usedArtist = true }
        }
        for w in q.optional where fields.contains(where: { match(w, $0) == 3 }) { s.quality += 1 }
        let words = q.required + q.optional
        // The artist counts as matched in full only when a word went to it: an album or song named after its artist
        // ("Weezer" by Weezer) must not beat the artist on the artist's own name (fix round 1, I2).
        for f in fields where f.role == .primary || (f.role == .artist && usedArtist) {
            let significant = f.significant
            guard !significant.isEmpty, significant.allSatisfy({ covers(words, $0) }) else { continue }
            s.fullFields += 1
            if f.role == .primary { s.primaryFull = true }
        }
        s.usesTitleAndArtist = usedPrimary && usedArtist && s.covered == q.required.count
        return s
    }
}
