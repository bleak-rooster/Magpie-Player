import Foundation
import MagpieCore

/// Round 27 A (owner item 17, 2026-11-14: "There should be an automix option whenever you're playing a song, or on an
/// artist page. When you hit automix, it find similar songs within your library and puts them into the queue … You should
/// be able to select the length of the automix and also select how variable you want the selection."; D306): which
/// library songs an Automix queues, and in what order. Pure and seeded, so the tests are exact.
///
/// The candidates are library songs only: Navidrome's similar songs (`getSimilarSongs2`, in its order), the seed artist's
/// own songs and the seed's genre's songs. Each variety takes a nearer or wider part of them and keeps artists apart.
public enum Automix {
    /// "select the length of the automix": 20, 50 (the default) or 100 songs.
    public enum Length: Int, CaseIterable, Sendable {
        case twenty = 20
        case fifty = 50
        case hundred = 100

        public static let standard = Length.fifty
    }

    /// "select how variable you want the selection": Close, Balanced (the default) or Adventurous.
    public enum Variety: String, CaseIterable, Sendable {
        case close
        case balanced
        case adventurous

        public static let standard = Variety.balanced
    }

    /// At most `most` songs by one artist in any `window` songs in a row.
    public struct Spacing: Sendable, Equatable {
        public var most: Int
        public var window: Int

        public init(most: Int, window: Int) { self.most = most; self.window = window }
    }

    /// Close: 2 in any 5; Balanced: 1 in any 4; Adventurous: 1 in any 6 (D306).
    public static func spacing(_ variety: Variety) -> Spacing {
        switch variety {
        case .close: Spacing(most: 2, window: 5)
        case .balanced: Spacing(most: 1, window: 4)
        case .adventurous: Spacing(most: 1, window: 6)
        }
    }

    /// The library songs a mix may take from.
    public struct Candidates: Sendable {
        /// Navidrome's similar songs, nearest first.
        public var similar: [Song]
        /// The seed artist's own songs.
        public var artistSongs: [Song]
        /// Songs of the seed's genre.
        public var genreSongs: [Song]

        public init(similar: [Song] = [], artistSongs: [Song] = [], genreSongs: [Song] = []) {
            self.similar = similar; self.artistSongs = artistSongs; self.genreSongs = genreSongs
        }
    }

    /// How far down Navidrome's list each variety reaches: Close the nearest 40%, Balanced 70%, Adventurous all of it.
    static func reach(_ variety: Variety) -> Double {
        switch variety {
        case .close: 0.4
        case .balanced: 0.7
        case .adventurous: 1
        }
    }

    /// How many places a song may move from Navidrome's order (seeded), so two mixes from one song differ a little.
    /// Adventurous shuffles its whole first tier instead.
    static func jitter(_ variety: Variety) -> Int {
        switch variety {
        case .close: 3
        case .balanced: 8
        case .adventurous: 0
        }
    }

    /// The mix: at most `length` songs (none when it is 0 or less; fewer when the library can't fill it).
    ///
    /// Two tiers. The first is the variety's own: Close the nearest 40% of Navidrome's list and the seed artist's songs;
    /// Balanced the nearest 70%; Adventurous all of it and the genre's songs, shuffled. The second is the rest (the
    /// artist's and the genre's songs, the list's further part). Each next song is the first in the first tier, then the
    /// second, that keeps the variety's spacing (counting `history`, the seed song, before the mix). Never a song of
    /// `history`, one already `played` in this mix, an `excluded` one (a Discover copy, a find, a missing file) or a
    /// second copy of a song (by id, or the same artist and strict title, `TopSongIdentity`). Ties keep Navidrome's order.
    public static func pick<R: RandomNumberGenerator>(_ candidates: Candidates, length: Int, variety: Variety,
                                                      history: [Song] = [], played: Set<String> = [],
                                                      excluded: (Song) -> Bool = { _ in false },
                                                      using rng: inout R) -> [Song] {
        guard length > 0 else { return [] }
        var seen = Set<String>(), seenTitles = Set<String>()
        for song in history { _ = admit(song, ids: &seen, titles: &seenTitles) }
        seen.formUnion(played)
        func clean(_ songs: [Song]) -> [Song] {
            var ids = seen, titles = seenTitles
            return songs.filter { !excluded($0) && admit($0, ids: &ids, titles: &titles) }
        }
        let similar = clean(candidates.similar)
        let cut = min(similar.count, Int((Double(similar.count) * reach(variety)).rounded(.up)))
        let near = Array(similar[..<cut]), far = Array(similar[cut...])
        let first: [Song], second: [Song]
        switch variety {
        case .close:
            first = jittered(near + clean(candidates.artistSongs), by: jitter(variety), using: &rng)
            second = jittered(far + clean(candidates.genreSongs), by: jitter(variety), using: &rng)
        case .balanced:
            first = jittered(near, by: jitter(variety), using: &rng)
            second = jittered(clean(candidates.artistSongs) + far + clean(candidates.genreSongs), by: jitter(variety),
                              using: &rng)
        case .adventurous:
            first = (similar + clean(candidates.genreSongs)).shuffled(using: &rng)
            second = clean(candidates.artistSongs)
        }

        let rule = spacing(variety)
        let back = max(rule.window - 1, 0)
        var recent = history.suffix(back).map(artistKey)
        // Each song's keys once (the strict title is the costly part); the tiers may share a song, so it is checked again.
        var pool = (first + second).map { (song: $0, title: titleKey($0), artist: artistKey($0)) }
        var mix: [Song] = []
        while mix.count < length {
            let window = recent.suffix(back)
            let next = pool.firstIndex { item in
                guard !seen.contains(item.song.id), item.title.isEmpty || !seenTitles.contains(item.title) else { return false }
                return window.filter { $0 == item.artist }.count < rule.most
            }
            guard let next else { break }
            let item = pool.remove(at: next)
            seen.insert(item.song.id)
            if !item.title.isEmpty { seenTitles.insert(item.title) }
            mix.append(item.song)
            recent.append(item.artist)
            if recent.count > back { recent.removeFirst(recent.count - back) }
        }
        return mix
    }

    /// `songs` with each moved up to `places` from its place (seeded); ties keep the given order.
    static func jittered<R: RandomNumberGenerator>(_ songs: [Song], by places: Int, using rng: inout R) -> [Song] {
        guard places > 0, songs.count > 1 else { return songs }
        return songs.enumerated()
            .map { (score: $0.offset + Int.random(in: 0...places, using: &rng), index: $0.offset, song: $0.element) }
            .sorted { $0.score != $1.score ? $0.score < $1.score : $0.index < $1.index }
            .map(\.song)
    }

    /// One artist, for spacing: the library's artist id, else the name as written.
    static func artistKey(_ song: Song) -> String {
        if let id = song.artistId, !id.isEmpty { return "id:" + id }
        return "name:" + song.artist.lowercased()
    }

    /// The same song by the same artist: their key and the strict title (empty when the title has no letters or digits).
    static func titleKey(_ song: Song) -> String {
        let title = TopSongIdentity.titleKey(song.title)
        return title.isEmpty ? "" : artistKey(song) + "|" + title
    }

    private static func admit(_ song: Song, ids: inout Set<String>, titles: inout Set<String>) -> Bool {
        let title = titleKey(song)
        guard !ids.contains(song.id), title.isEmpty || !titles.contains(title) else { return false }
        ids.insert(song.id)
        if !title.isEmpty { titles.insert(title) }
        return true
    }

    /// A small seedable generator (SplitMix64) so a mix can be reproduced in tests; the app seeds it at random.
    public struct Generator: RandomNumberGenerator, Sendable {
        private var state: UInt64

        public init(seed: UInt64) { state = seed }

        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
