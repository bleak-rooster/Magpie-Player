import Foundation
import MagpieCore

public struct GenreGroup: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct GenreGroupSection: Hashable, Sendable {
    public var group: GenreGroup
    public var genres: [Genre]
    public var albumCount: Int
    public var songCount: Int
}

/// Groups a server's raw genre list under about 16 parents for browsing. Pure logic: a hand-written alias map, ordered
/// whole-word keyword rules, client-side splitting of multi-value strings, and the owner's overrides (`GenrePreferences`).
/// The table is our own work from general music knowledge. The genre rows themselves are never changed.
public enum GenreGroups {
    /// Spec order.
    public static let builtIn: [GenreGroup] = [
        ("rock", "Rock"), ("pop", "Pop"), ("electronic", "Electronic"), ("hiphop", "Hip-Hop & Rap"), ("rnb", "R&B & Soul"),
        ("jazz", "Jazz"), ("blues", "Blues"), ("classical", "Classical"), ("country", "Country & Folk"), ("metal", "Metal"),
        ("punk", "Punk"), ("reggae", "Reggae & Ska"), ("latin", "Latin"), ("world", "World"),
        ("soundtrack", "Soundtrack & Stage"), ("other", "Other"),
    ].map { GenreGroup(id: $0.0, name: $0.1) }

    /// Folds case and diacritics, maps `-` and `_` to spaces, collapses whitespace and trims.
    public static func key(_ genre: String) -> String {
        let folded = genre.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { !apostrophes.contains($0) }
            .map { $0 == "_" || dashes.contains($0) ? " " : $0 }
        return String(folded).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Always splits on `;`, `/` and `,`. Splits on ` & ` only when every part gets a group other than "other", so
    /// "Rock & Pop" splits but "Drum & Bass" and "Rhythm & Blues" don't.
    public static func split(_ genre: String) -> [String] {
        let hard = genre.split(whereSeparator: { ";/,".contains($0) })
            .map(tidy).filter { !$0.isEmpty }
        return hard.flatMap { piece -> [String] in
            guard aliases[key(piece)] == nil else { return [piece] }
            let halves = piece.components(separatedBy: " & ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard halves.count > 1, halves.allSatisfy({ !$0.isEmpty && groupId(for: $0) != "other" }) else { return [piece] }
            return halves
        }
    }

    public static func groupId(for genre: String) -> String {
        let k = key(genre)
        if let alias = aliases[k] { return alias }
        let words = k.split(separator: " ").map(String.init)
        var best = Int.max
        for word in words {
            if let i = exactWords[word] { best = min(best, i) }
            for (prefix, i) in prefixWords where i < best && word.hasPrefix(prefix) { best = i }
        }
        return best == Int.max ? "other" : rules[best].group
    }

    /// Hides empty genres, groups the rest (a multi-value genre sits in each of its parts' groups), applies the owner's
    /// overrides, names and custom groups, and drops hidden and empty groups. An override that points at a group that no
    /// longer exists (capped or partial preferences) falls back to the rules.
    public static func grouped(_ genres: [Genre], preferences: GenrePreferences) -> [GenreGroupSection] {
        var seenGroups = Set(builtIn.map(\.id))
        let order = builtIn.map(\.id) + preferences.customGroups.filter { seenGroups.insert($0).inserted }
        let known = Set(order)
        func target(_ part: String) -> String {
            if let g = preferences.assignments[key(part)], known.contains(g) { return g }
            return groupId(for: part)
        }
        var members: [String: [Genre]] = [:]
        for genre in genres where genre.albumCount > 0 || genre.songCount > 0 {
            var ids: [String]
            if let whole = preferences.assignments[key(genre.name)], known.contains(whole) { ids = [whole] }
            else { ids = split(genre.name).map(target) }
            if ids.isEmpty { ids = ["other"] }
            var seen = Set<String>()
            for id in ids where seen.insert(id).inserted { members[id, default: []].append(genre) }
        }
        return order.compactMap { id in
            guard !preferences.hidden.contains(id), let list = members[id], !list.isEmpty else { return nil }
            let name = preferences.groupNames[id] ?? builtIn.first { $0.id == id }?.name ?? "Custom"
            return GenreGroupSection(group: GenreGroup(id: id, name: name), genres: sorted(list),
                                     albumCount: list.reduce(0) { $0 + $1.albumCount }, songCount: list.reduce(0) { $0 + $1.songCount })
        }
    }

    /// The flat "All genres" list: non-empty genres, A–Z.
    public static func allGenres(_ genres: [Genre]) -> [Genre] {
        sorted(genres.filter { $0.albumCount > 0 || $0.songCount > 0 })
    }

    // MARK: - Table

    private static func sorted(_ genres: [Genre]) -> [Genre] {
        genres.sorted {
            let c = $0.name.localizedCaseInsensitiveCompare($1.name)
            return c == .orderedSame ? $0.name < $1.name : c == .orderedAscending
        }
    }

    private static let dashes: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}"]
    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}"]

    /// Display tidy for a split piece: dashes become `-`, any run of whitespace (non-breaking too) becomes one space.
    private static func tidy<S: StringProtocol>(_ s: S) -> String {
        String(s.map { dashes.contains($0) ? "-" : $0 }).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Exact (folded) names that the keyword rules would get wrong or miss. Post-punk goes to rock (a guitar-band lineage;
    /// the "punk" keyword would otherwise take it).
    private static let aliases: [String: String] = [
        "hiphop": "hiphop", "hardcore hip hop": "hiphop",
        "trip hop": "electronic", "triphop": "electronic", "disco": "electronic", "dance": "electronic", "edm": "electronic",
        "house": "electronic", "industrial": "electronic", "dub techno": "electronic", "electro swing": "electronic",
        "liquid funk": "electronic", "liquid drum & bass": "electronic", "liquid drum and bass": "electronic",
        "drum n bass": "electronic", "dnb": "electronic",
        "kpop": "pop", "jpop": "pop", "chamber pop": "pop",
        "alternative": "rock", "indie": "rock", "new wave": "rock", "post punk": "rock", "psychedelic": "rock",
        "rocknroll": "rock", "rock n roll": "rock", "drum & bass": "electronic", "drum and bass": "electronic",
        "dubstep": "electronic", "uk garage": "electronic",
        "alt rock": "rock", "alternative rock": "rock", "classic rock": "rock", "indie rock": "rock",
        "rhythm & blues": "rnb", "rhythm and blues": "rnb", "rnb": "rnb", "r and b": "rnb",
        "j pop": "pop", "k pop": "pop",
        "rock & roll": "rock", "rock and roll": "rock", "rockabilly": "rock",
        "new age": "electronic", "lo fi": "electronic", "lofi": "electronic",
        "singer songwriter": "country", "bollywood": "world", "gospel": "rnb",
    ]

    /// First rule with a whole-word match wins. A keyword ending in `*` matches a word prefix.
    private static let rules: [(group: String, words: [String])] = [
        ("metal", ["metal", "metal*"]),
        ("punk", ["punk", "hardcore", "emo"]),
        ("hiphop", ["hip", "rap", "trap", "grime", "drill"]),
        ("rnb", ["r&b", "soul", "funk", "motown"]),
        ("jazz", ["jazz", "swing", "bebop", "bossa"]),
        ("blues", ["blues"]),
        ("classical", ["classical", "baroque", "opera", "orchestr*", "symphon*", "chamber"]),
        ("country", ["country", "folk", "bluegrass", "americana"]),
        ("reggae", ["reggae", "ska", "dub", "dancehall"]),
        ("latin", ["latin", "salsa", "reggaeton", "bachata", "cumbia", "tango", "samba"]),
        ("soundtrack", ["soundtrack", "score", "musical", "stage"]),
        ("rock", ["rock", "grunge", "shoegaze"]),
        ("electronic", ["electr*", "techno", "house", "trance", "edm", "ambient", "idm", "synth*", "downtempo", "breakbeat", "electronique"]),
        ("pop", ["pop"]),
        ("world", ["afro*", "world", "celtic", "flamenco", "chanson", "fado"]),
    ]

    /// The rule index each whole keyword and each keyword prefix belongs to (the lowest index wins).
    private static let exactWords: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, rule) in rules.enumerated() { for w in rule.words where !w.hasSuffix("*") && m[w] == nil { m[w] = i } }
        return m
    }()
    private static let prefixWords: [(String, Int)] = rules.enumerated().flatMap { i, rule in
        rule.words.filter { $0.hasSuffix("*") }.map { (String($0.dropLast()), i) }
    }
}
