import Foundation

// Round 15 C4 (D141–D145): a genre's or a genre group's albums, sorted and filtered, a page at a time. The owner's
// groups run to thousands of albums (Rock 6,383, Metal 3,261), so the server sorts and filters (Navidrome's native
// `/api/album`) and the phone holds only the pages scrolled to. Where the server can't do it (a decade, no native API,
// offline, Downloaded only) the phone sorts and filters a bounded list itself.

/// How a genre page's albums are ordered. The raw values are stored (Preferences), so they never change.
public enum GenreAlbumSort: String, CaseIterable, Codable, Hashable, Sendable {
    case name, artist, newest, oldest, recentlyAdded, mostPlayed, random

    public var title: String {
        switch self {
        case .name: "Name"
        case .artist: "Artist"
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .recentlyAdded: "Recently added"
        case .mostPlayed: "Most played"
        case .random: "Random"
        }
    }

    public var symbol: String {
        switch self {
        case .name: "textformat"
        case .artist: "music.mic"
        case .newest: "calendar.badge.clock"
        case .oldest: "calendar"
        case .recentlyAdded: "clock.arrow.circlepath"
        case .mostPlayed: "flame"
        case .random: "shuffle"
        }
    }
}

/// What a genre page's albums are narrowed to. Not kept between visits (only the sort is, D143).
public struct GenreAlbumFilter: Hashable, Sendable {
    /// The genres picked from the page's own (a group's sub-genres); empty: all of them.
    public var genres: Set<String>
    /// A decade's first year (1990: 1990–1999).
    public var decade: Int?
    /// Album or artist (typed; see `searchText`).
    public var text: String
    public var favouritesOnly: Bool
    public var downloadedOnly: Bool

    /// Longer text is cut to this.
    public static let maxText = 100

    public init(genres: Set<String> = [], decade: Int? = nil, text: String = "", favouritesOnly: Bool = false,
                downloadedOnly: Bool = false) {
        self.genres = genres; self.decade = decade; self.text = text
        self.favouritesOnly = favouritesOnly; self.downloadedOnly = downloadedOnly
    }

    public static let none = GenreAlbumFilter()

    /// The text to filter by: trimmed, at most `maxText` characters; nil when blank.
    public var searchText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maxText))
    }

    public var isActive: Bool {
        !genres.isEmpty || decade != nil || searchText != nil || favouritesOnly || downloadedOnly
    }

    /// The genres asked for: the picked ones that are the page's, else all of the page's (in the page's order).
    public func genres(of page: [String]) -> [String] {
        let picked = page.filter { genres.contains($0) }
        return picked.isEmpty ? page : picked
    }
}

/// Decades: labels and the ones a list of years spans.
public enum Decades {
    /// 1994 → 1990. Nil for an unknown year (0 or less).
    public static func decade(of year: Int?) -> Int? {
        guard let year, year > 0 else { return nil }
        return year - year % 10
    }

    /// "1990s".
    public static func label(_ decade: Int) -> String { "\(decade)s" }

    /// Every decade from the oldest year to the newest, newest first (unknown years left out).
    public static func spanning(oldest: Int?, newest: Int?) -> [Int] {
        guard let from = decade(of: oldest), let to = decade(of: newest), from <= to else {
            return [decade(of: oldest), decade(of: newest)].compactMap { $0 }.uniqued()
        }
        return Array(stride(from: to, through: from, by: -10))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

/// One server read's question: the genres, the order, and the filters the server applies.
public struct GenreAlbumQuery: Hashable, Sendable {
    /// Genre names, never empty.
    public var genres: [String]
    public var sort: GenreAlbumSort
    public var text: String?
    public var favouritesOnly: Bool
    /// Random's seed, so its pages follow on from each other (Navidrome's `seed`).
    public var seed: Int

    public init(genres: [String], sort: GenreAlbumSort, text: String? = nil, favouritesOnly: Bool = false, seed: Int = 0) {
        self.genres = genres; self.sort = sort; self.text = text; self.favouritesOnly = favouritesOnly; self.seed = seed
    }

    /// The same question in year order (oldest first): a decade's window is found in it.
    public var inYearOrder: GenreAlbumQuery { var q = self; q.sort = .oldest; return q }
}

/// One page of a server read, and how many albums the whole read has.
public struct GenreAlbumPage: Sendable, Equatable {
    public var albums: [Album]
    public var total: Int

    public init(albums: [Album], total: Int) { self.albums = albums; self.total = total }
}

/// Where a genre page's albums come from a page at a time (the server's native album list).
public protocol GenreAlbumSource: Sendable {
    /// Albums `start..<end` of `query`'s list.
    func page(_ query: GenreAlbumQuery, start: Int, end: Int) async throws -> GenreAlbumPage
}

/// The phone's own sort and filter, for a bounded list (offline, Downloaded only, no native API, a decade).
public enum GenreAlbumOrder {
    /// `albums` narrowed by the filter's text, decade and Favourites only (genres and Downloaded only are the caller's:
    /// it knows where each album came from), in `sort`'s order. Random is the same for the same seed.
    public static func apply(_ albums: [Album], sort: GenreAlbumSort, filter: GenreAlbumFilter, seed: Int = 0) -> [Album] {
        let text = filter.searchText.map(fold)
        let kept = albums.filter { album in
            if filter.favouritesOnly, !album.starred { return false }
            if let decade = filter.decade, Decades.decade(of: album.year) != decade { return false }
            if let text, !fold(album.name).contains(text), !fold(album.artist).contains(text) { return false }
            return true
        }
        return sorted(kept, by: sort, seed: seed)
    }

    public static func sorted(_ albums: [Album], by sort: GenreAlbumSort, seed: Int = 0) -> [Album] {
        func byName(_ a: Album, _ b: Album) -> Bool {
            let c = a.name.localizedStandardCompare(b.name)
            return c == .orderedSame ? a.id < b.id : c == .orderedAscending
        }
        switch sort {
        case .name:
            return albums.sorted(by: byName)
        case .artist:
            return albums.sorted { a, b in
                let c = a.artist.localizedStandardCompare(b.artist)
                return c == .orderedSame ? byName(a, b) : c == .orderedAscending
            }
        case .newest, .oldest:
            let newest = sort == .newest
            return albums.sorted { a, b in
                let (x, y) = (a.year ?? 0, b.year ?? 0)
                if x != y { return newest ? x > y : x < y }
                return byName(a, b)
            }
        case .recentlyAdded:
            return albums.sorted { a, b in
                let (x, y) = (a.created ?? .distantPast, b.created ?? .distantPast)
                return x == y ? byName(a, b) : x > y
            }
        case .mostPlayed:
            return albums.sorted { a, b in
                let (x, y) = (a.playCount ?? 0, b.playCount ?? 0)
                return x == y ? byName(a, b) : x > y
            }
        case .random:
            var generator = SeededGenerator(seed: UInt64(bitPattern: Int64(seed)))
            return albums.sorted(by: byName).shuffled(using: &generator)
        }
    }

    /// Case- and accent-insensitive.
    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}

/// SplitMix64: the same shuffle for the same seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A genre page's server list, a page at a time (D141, D142).
///
/// - Without a decade: `query`'s list as the server sorts and filters it, `pageSize` at a time.
/// - With a decade (Navidrome filters by one exact year only): the decade's window is found in the year-ordered list by
///   binary search over single-album reads (about 2 × log2 of the count), then read. A window of at most `windowSortCap`
///   albums is read whole and put in the chosen order on the phone; a larger one is read a page at a time in year order
///   (newest first for Newest, else oldest first) and `inYearOrder` says so.
@MainActor public final class GenreAlbumPager {
    public static let pageSize = 100
    public static let windowSortCap = 1000

    public let query: GenreAlbumQuery
    public let decade: Int?
    public private(set) var albums: [Album] = []
    /// How many albums the list has; nil until the first read.
    public private(set) var total: Int?
    /// True when a decade had too many albums to sort on the phone: they are in year order instead.
    public private(set) var inYearOrder = false

    private let source: GenreAlbumSource
    /// The next server position to read (forwards), or the window's remaining range (a backwards decade read).
    private var next = 0
    private var window: Range<Int>?
    private var backwards = false
    private var seen = Set<String>()
    private var exhausted = false

    public init(source: GenreAlbumSource, query: GenreAlbumQuery, decade: Int? = nil) {
        self.source = source; self.query = query; self.decade = decade
    }

    public var hasMore: Bool { !exhausted }

    /// The first page (or the decade's window).
    public func loadFirst() async throws {
        albums = []; seen = []; next = 0; exhausted = false; inYearOrder = false; window = nil; backwards = false
        guard let decade else {
            try await loadMore()
            return
        }
        let yearQuery = query.inYearOrder
        let first = try await source.page(yearQuery, start: 0, end: 1)
        let count = first.total
        let lo = try await firstIndex(in: yearQuery, count: count, atLeast: decade, known: first.albums.first)
        let hi = try await firstIndex(in: yearQuery, count: count, atLeast: decade + 10, known: first.albums.first,
                                      from: lo)
        total = hi - lo
        guard hi > lo else { exhausted = true; return }
        if hi - lo <= Self.windowSortCap {
            var read: [Album] = []
            var at = lo
            while at < hi {
                let end = min(hi, at + 250)
                let page = try await source.page(yearQuery, start: at, end: end)
                read += page.albums
                if page.albums.isEmpty { break }
                at = end
            }
            let inDecade = read.filter { Decades.decade(of: $0.year) == decade && seen.insert($0.id).inserted }
            albums = GenreAlbumOrder.sorted(inDecade, by: query.sort, seed: query.seed)
            exhausted = true
            return
        }
        inYearOrder = query.sort != .oldest && query.sort != .newest
        window = lo..<hi
        backwards = query.sort == .newest
        next = backwards ? hi : lo
        try await loadMore()
    }

    /// The next page; nothing once the list has been read to its end.
    public func loadMore() async throws {
        guard !exhausted else { return }
        if let window {
            let yearQuery = query.inYearOrder
            if backwards {
                let start = max(window.lowerBound, next - Self.pageSize)
                let page = try await source.page(yearQuery, start: start, end: next)
                append(page.albums.reversed())
                next = start
                if start <= window.lowerBound || page.albums.isEmpty { exhausted = true }
            } else {
                let end = min(window.upperBound, next + Self.pageSize)
                let page = try await source.page(yearQuery, start: next, end: end)
                append(page.albums)
                next = end
                if end >= window.upperBound || page.albums.isEmpty { exhausted = true }
            }
            return
        }
        let page = try await source.page(query, start: next, end: next + Self.pageSize)
        total = page.total
        append(page.albums)
        next += Self.pageSize
        // A short page, or nothing new (a server ignoring the offset), is the end.
        if page.albums.count < Self.pageSize || next >= page.total { exhausted = true }
    }

    private func append<S: Sequence>(_ page: S) where S.Element == Album {
        albums += page.filter { seen.insert($0.id).inserted }
    }

    /// The first position in `query`'s year order whose album is from `year` or later (`count` when none is).
    private func firstIndex(in query: GenreAlbumQuery, count: Int, atLeast year: Int, known: Album?,
                            from start: Int = 0) async throws -> Int {
        try await Self.firstIndex(source, in: query, count: count, atLeast: year, known: known, from: start)
    }

    private static func firstIndex(_ source: GenreAlbumSource, in query: GenreAlbumQuery, count: Int, atLeast year: Int,
                                   known: Album?, from start: Int = 0) async throws -> Int {
        var lo = start, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            let album: Album?
            if mid == 0, let known { album = known } else { album = try await source.page(query, start: mid, end: mid + 1).albums.first }
            guard let album else { hi = mid; continue }   // past the end (the list shrank meanwhile)
            if (album.year ?? 0) >= year { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// The oldest and newest known years of `query`'s list (albums without a year sort first and are skipped): the
    /// decades a page offers. A few single-album reads.
    public static func yearSpan(_ source: GenreAlbumSource, query: GenreAlbumQuery) async throws -> (oldest: Int?, newest: Int?) {
        var newestFirst = query
        newestFirst.sort = .newest
        let newest = try await source.page(newestFirst, start: 0, end: 1).albums.first?.year
        let oldestFirst = query.inYearOrder
        let first = try await source.page(oldestFirst, start: 0, end: 1)
        if let year = first.albums.first?.year, year > 0 { return (year, newest) }
        let at = try await firstIndex(source, in: oldestFirst, count: first.total, atLeast: 1, known: first.albums.first)
        guard at < first.total else { return (nil, newest) }
        return (try await source.page(oldestFirst, start: at, end: at + 1).albums.first?.year, newest)
    }
}
