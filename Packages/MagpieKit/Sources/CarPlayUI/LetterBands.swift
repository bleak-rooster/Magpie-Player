import Foundation
import MagpieCore
import Search

// Round 13 items 3 and 4: the car's Artists, Songs and Albums open on five letter groups (A–E, F–J, K–O, P–T, U–Z & #),
// always, each with its count. CarPlay keeps the left edge for its own tab and app area, so the groups are rows, not a
// side index. A group opens its list in letter sections, so CarPlay's letter scrubber still works inside it. A group
// over the car's item limit is split into pages ("A–E (1 of 3)") on the same screen, so every item stays reachable
// within D12's depth: tab → groups → group → page → Now Playing. Albums start with Newest (every album, newest first),
// and inside a group each letter's albums are newest first. This replaces Y2's over-limit-only letters screen for these
// three lists; Playlists keep Y2's.

/// One of the five letter groups.
public enum CPLetterBand: Int, CaseIterable, Sendable, Hashable {
    case aToE, fToJ, kToO, pToT, uToZ

    public var title: String {
        switch self {
        case .aToE: "A\u{2013}E"
        case .fToJ: "F\u{2013}J"
        case .kToO: "K\u{2013}O"
        case .pToT: "P\u{2013}T"
        case .uToZ: "U\u{2013}Z & #"
        }
    }

    /// The letters it holds, in the order its list shows them ("#" last, as the title says).
    public var keys: [String] {
        let letters = LetterIndex.letters.dropFirst()   // A…Z
        let start = rawValue * 5
        let own = Array(letters.dropFirst(start).prefix(self == .uToZ ? 6 : 5))
        return self == .uToZ ? own + ["#"] : own
    }

    /// The group a letter ("A"…"Z" or "#") files under.
    public static func of(key: String) -> CPLetterBand {
        allCases.first { $0.keys.contains(key) } ?? .uToZ
    }
}

/// Where Songs' five groups lie in the server's title order (`/api/song?_sort=title`): read by seeks of single rows, never
/// by paging through every song. "#" songs sort both first (digits, most symbols) and last (other scripts).
public struct CPSongIndex: Sendable, Hashable {
    public var total: Int
    /// The first offset at or after A, F, K, P and U, then the first past Z.
    public var starts: [Int]

    public init(total: Int, starts: [Int]) {
        let total = max(0, total)
        self.total = total
        // Monotone and within the list, whatever the reads said.
        var last = 0
        self.starts = (0..<6).map { i in
            last = min(max(starts.indices.contains(i) ? starts[i] : total, last), total)
            return last
        }
    }

    /// The offset ranges of `band`, in the order its list shows them: U–Z, then the "#" songs that sort first, then those
    /// that sort last. Empty ranges are left out.
    public func ranges(_ band: CPLetterBand) -> [Range<Int>] {
        let ranges: [Range<Int>] = switch band {
        case .uToZ: [starts[4]..<starts[5], 0..<starts[0], starts[5]..<total]
        default: [starts[band.rawValue]..<starts[band.rawValue + 1]]
        }
        return ranges.filter { !$0.isEmpty }
    }

    func count(_ band: CPLetterBand) -> Int { ranges(band).reduce(0) { $0 + $1.count } }

    /// Reads the index by seeks over the server's title order (`nameAt`: the title at an offset, nil past the end):
    /// about log2 of the song count single-row reads per boundary, the six seeks side by side.
    public static func read(total: Int, nameAt: @escaping @Sendable (Int) async throws -> String?) async throws -> CPSongIndex {
        async let a = LetterIndex.seek("A", total: total, nameAt: nameAt)
        async let f = LetterIndex.seek("F", total: total, nameAt: nameAt)
        async let k = LetterIndex.seek("K", total: total, nameAt: nameAt)
        async let p = LetterIndex.seek("P", total: total, nameAt: nameAt)
        async let u = LetterIndex.seek("U", total: total, nameAt: nameAt)
        async let pastZ = LetterIndex.seekPastZ(total: total, nameAt: nameAt)
        return CPSongIndex(total: total, starts: try await [a, f, k, p, u, pastZ])
    }

    /// Offline: the phone's songs put in the server's title order (folded, articles kept; "#" below "a" first, other
    /// scripts last), so the same index and offsets apply.
    public static func titleOrder<T>(_ items: [(T, String)]) -> [(T, String)] {
        items.enumerated().sorted { l, r in
            let (a, b) = (l.element.1, r.element.1)
            let (ra, rb) = (LetterIndex.rank(a), LetterIndex.rank(b))
            if ra != rb { return ra < rb }
            let order = a.compare(b, options: [.caseInsensitive, .diacriticInsensitive])
            return order == .orderedSame ? l.offset < r.offset : order == .orderedAscending
        }.map(\.element)
    }

    /// The index of titles already in the server's order (`titleOrder`).
    public init(sortedTitles titles: [String]) {
        let ranks = titles.map { LetterIndex.rank($0) }
        func first(_ rank: Int) -> Int { ranks.firstIndex { $0 >= rank } ?? titles.count }
        self.init(total: titles.count, starts: [first(1), first(6), first(11), first(16), first(21), first(27)])
    }
}

extension CarPlayRows {
    static let newestTitle = "Newest"

    /// One row of the group screen before paging: Newest or a letter group, its size, and what a run of it opens.
    struct BandColumn {
        var id: String
        var title: String
        var count: Int
        /// The screen a run (positions within the column) opens, titled `title`, and its "first to last" line when
        /// split into pages (nil: the count is said instead).
        var open: (_ range: Range<Int>, _ title: String) -> (destination: CPDestination, span: String?)
    }

    /// Artists on their five groups; a group opens its artists in letter sections.
    public static func artistBands(_ artists: [Artist], maxItems: Int = .max) -> [CPSectionModel] {
        let entries = unique(artists, \.id).map { artist in
            let name = display(artist.name, unknownArtist)
            let row = CPRowModel(id: "artist.\(artist.id)", title: name, detail: albumCount(artist.albumCount),
                                 artworkKey: artist.coverArtId, action: .open(.artist(id: artist.id, name: name)))
            return letterEntry(name: artist.name, articles: LetterIndex.navidromeArticles, row: row)
        }
        return bandScreen(entryColumns(entries, byName: true), kind: .artists, maxItems: maxItems)
    }

    /// Albums: Newest (every album, newest first), then the five groups, each letter's albums newest first.
    /// - Parameter total: how many albums the library has when only some were read ("Showing 5000 of N").
    public static func albumBands(_ albums: [Album], maxItems: Int = .max, total: Int? = nil) -> [CPSectionModel] {
        let shown = unique(albums, \.id)
        let newest = shown.enumerated().sorted { isNewer($0, $1) }.map(\.element)
        let newestRows = newest.map { album in
            var row = albumRow(album, id: "album.\(album.id)")
            row.detail = [album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " \u{00B7} ")
            return row
        }
        let newestColumn = BandColumn(id: "bands.newest", title: newestTitle, count: newestRows.count) { range, title in
            let rows = Array(newestRows[range])
            let years = [newest[range.lowerBound].year, newest[range.upperBound - 1].year]
            let span = years.contains(nil) ? nil : years.map { String($0!) }.joined(separator: " to ")
            return (.letterGroup(title: title, sections: [CPSectionModel(header: nil, rows: rows)]), span)
        }
        // Each letter's albums newest first: the entries go in newest order, and the sort by letter keeps it.
        let entries = newest.map { album in
            letterEntry(name: album.name, articles: LetterIndex.navidromeArticles, row: albumRow(album, id: "album.\(album.id)"))
        }
        let note = total.flatMap { $0 > shown.count ? "Showing \(shown.count) of \($0)" : nil }
        return bandScreen([newestColumn] + entryColumns(entries, byName: false), kind: .albums, maxItems: maxItems,
                          note: note)
    }

    /// Songs on their five groups, from the server's title order; a group (or page) reads its songs when it opens.
    public static func songBands(_ index: CPSongIndex, maxItems: Int = .max) -> [CPSectionModel] {
        let columns = CPLetterBand.allCases.map { band in
            let ranges = index.ranges(band)
            return BandColumn(id: "bands.\(band.rawValue)", title: band.title, count: index.count(band)) { range, title in
                (.songRange(title: title, ranges: slice(ranges, range)), nil)
            }
        }
        return bandScreen(columns, kind: .songs, maxItems: maxItems)
    }

    /// A song group's list (a leaf): letter sections in the order read, each song playing the list from it. When only
    /// some of the group was read (`total`), the last row says how many.
    public static func songPage(_ songs: [Song], total: Int?, playingId: String?) -> [CPSectionModel] {
        guard !songs.isEmpty else { return state(.empty) }
        let entries = songs.enumerated().map { i, song in
            CPLetterEntry(key: LetterIndex.key(song.title), sortName: song.title,
                          row: CPRowModel(id: "song.\(i).\(song.id)", title: display(song.title, untitled), detail: song.artist,
                                          artworkKey: song.coverArtId, playing: song.id == playingId,
                                          action: .play(.songs(songs, startAt: i))))
        }
        let note = total.flatMap { $0 > songs.count ? "Showing \(songs.count) of \($0)" : nil }
        return letterSections(entries) + (note.map { [CPSectionModel(header: nil, rows: [CPRowModel(id: "az.more", title: $0,
                                                                                                    action: .none)])] } ?? [])
    }

    // MARK: - Building the group screen

    /// Newest first: the later year, then the later `created`; an album without them after those with.
    static func isNewer(_ l: (offset: Int, element: Album), _ r: (offset: Int, element: Album)) -> Bool {
        let (a, b) = (l.element, r.element)
        if a.year != b.year { return (a.year ?? .min) > (b.year ?? .min) }
        if a.created != b.created { return (a.created ?? .distantPast) > (b.created ?? .distantPast) }
        let byName = a.name.localizedStandardCompare(b.name)
        return byName == .orderedSame ? l.offset < r.offset : byName == .orderedAscending
    }

    /// The five groups of in-memory entries: each group's entries by its letters' order, then by name (`byName`) or as
    /// given.
    static func entryColumns(_ entries: [CPLetterEntry], byName: Bool) -> [BandColumn] {
        CPLetterBand.allCases.map { band in
            let order = Dictionary(uniqueKeysWithValues: band.keys.enumerated().map { ($1, $0) })
            let members = entries.enumerated().filter { order[$0.element.key] != nil }.sorted { l, r in
                let (a, b) = (l.element, r.element)
                if a.key != b.key { return order[a.key]! < order[b.key]! }
                if byName {
                    let byName = a.sortName.localizedStandardCompare(b.sortName)
                    if byName != .orderedSame { return byName == .orderedAscending }
                }
                return l.offset < r.offset
            }.map(\.element)
            return BandColumn(id: "bands.\(band.rawValue)", title: band.title, count: members.count) { range, title in
                let run = Array(members[range])
                let span = "\(run.first?.row.title ?? "") to \(run.last?.row.title ?? "")"
                return (.letterGroup(title: title, sections: letterSections(run)), span)
            }
        }
    }

    /// The group screen: one row per column, or one per page of a column over the page size; an empty letter group
    /// shows, disabled ("No artists"). `note` takes the last row.
    static func bandScreen(_ columns: [BandColumn], kind: CPLetterKind, maxItems: Int, note: String? = nil) -> [CPSectionModel] {
        guard columns.contains(where: { $0.count > 0 }) else { return state(.empty) }
        let noteRow = note.map { CPRowModel(id: "az.more", title: $0, action: .none) }
        let screen = max(columns.count, maxItems - (noteRow == nil ? 0 : 1))
        let size = bandPageSize(columns.map(\.count), listLimit: maxItems, screenLimit: screen)
        let rows = columns.flatMap { column -> [CPRowModel] in
            guard column.count > 0 else {
                return [CPRowModel(id: column.id, title: column.title, detail: kind.none, action: .none)]
            }
            let pages = pageCount(column.count, size)
            guard pages > 1 else {
                let opened = column.open(0..<column.count, column.title)
                return [CPRowModel(id: column.id, title: column.title, detail: kind.count(column.count),
                                   action: .open(opened.destination))]
            }
            return (0..<pages).map { page in
                let range = (page * size)..<min((page + 1) * size, column.count)
                let title = "\(column.title) (\(page + 1) of \(pages))"
                let opened = column.open(range, title)
                return CPRowModel(id: "\(column.id).\(page + 1)", title: title, detail: opened.span ?? kind.count(range.count),
                                  action: .open(opened.destination))
            }
        }
        return [CPSectionModel(header: nil, rows: rows + (noteRow.map { [$0] } ?? []))]
    }

    /// Pages of `size` for `count` items (an empty column still takes its row). Never overflows.
    static func pageCount(_ count: Int, _ size: Int) -> Int { count <= 0 ? 1 : (count - 1) / max(1, size) + 1 }

    /// The page size: the car's list limit, grown (by halves) until every column's pages fit the group screen.
    static func bandPageSize(_ counts: [Int], listLimit: Int, screenLimit: Int) -> Int {
        let largest = counts.max() ?? 0
        var size = max(1, listLimit)
        while size < largest, counts.reduce(0, { $0 + pageCount($1, size) }) > screenLimit {
            size += max(1, size / 2)
        }
        return size
    }

    /// The offsets of positions `range` within the concatenation of `ranges`.
    static func slice(_ ranges: [Range<Int>], _ range: Range<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var position = 0
        for r in ranges {
            let lower = max(range.lowerBound, position), upper = min(range.upperBound, position + r.count)
            if lower < upper { out.append((r.lowerBound + lower - position)..<(r.lowerBound + upper - position)) }
            position += r.count
        }
        return out
    }
}
