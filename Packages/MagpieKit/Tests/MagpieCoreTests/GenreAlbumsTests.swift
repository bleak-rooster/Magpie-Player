import Foundation
import os
import Testing
@testable import MagpieCore

/// A stand-in for Navidrome's `/api/album` (v0.63/0.64 behaviour): filters, then orders as the server's sort mappings
/// do (Newest/Oldest by the original date first, then the album's own year; `recently_played` is `play_count > 0`), and
/// notes every read. Its own ordering, not the app's.
///
/// - `unstableTies`: the server orders by the sort's first key only (as `play_count` does) and ties come back in a new
///   order on every read, as SQLite may give them across separate LIMIT/OFFSET queries.
/// - `ignoresOffset`: every read answers the first page.
private final class FakeAlbumServer: GenreAlbumSource, @unchecked Sendable {
    struct Row { var album: Album; var genres: Set<String> }
    let rows: [Row]
    let unstableTies: Bool
    let ignoresOffset: Bool
    private let lock = OSAllocatedUnfairLock(initialState: [(GenreAlbumQuery, Int, Int)]())
    init(_ rows: [Row], unstableTies: Bool = false, ignoresOffset: Bool = false) {
        self.rows = rows; self.unstableTies = unstableTies; self.ignoresOffset = ignoresOffset
    }
    var reads: [(query: GenreAlbumQuery, start: Int, end: Int)] { lock.withLock { $0.map { ($0.0, $0.1, $0.2) } } }

    /// The server's first sort key (smaller first), and its tiebreak (name, then id: the mappings end in a name).
    private func key(_ a: Album, _ sort: GenreAlbumSort) -> (Double, String) {
        let year = Double(a.originalYear ?? a.year ?? 0)
        let name = a.name.lowercased() + "|" + a.id
        switch sort {
        case .name: return (0, name)
        case .artist: return (0, a.artist.lowercased() + "|" + name)
        case .oldest: return (year, name)
        case .newest: return (-year, name)
        case .recentlyAdded: return (-(a.created?.timeIntervalSince1970 ?? 0), name)
        case .mostPlayed: return (-Double(a.playCount ?? 0), name)
        case .random: return (0, name)
        }
    }

    func page(_ query: GenreAlbumQuery, start: Int, end: Int) async throws -> GenreAlbumPage {
        lock.withLock { $0.append((query, start, end)) }
        let wanted = Set(query.genres)
        let text = query.text?.lowercased()
        var all = rows.filter { !$0.genres.isDisjoint(with: wanted) }.map(\.album).filter { a in
            if query.favouritesOnly, !a.starred { return false }
            if query.playedOnly, (a.playCount ?? 0) <= 0 { return false }
            if let text, !a.name.lowercased().contains(text), !a.artist.lowercased().contains(text) { return false }
            return true
        }
        if unstableTies, query.sort == .mostPlayed {
            // `play_count` has no tiebreak in Navidrome's mappings (the others end in a name).
            all.shuffle()
            all.sort { key($0, query.sort).0 < key($1, query.sort).0 }   // Swift's sort isn't stable either
        } else {
            all.sort { let (x, y) = (key($0, query.sort), key($1, query.sort)); return x.0 != y.0 ? x.0 < y.0 : x.1 < y.1 }
        }
        let from = ignoresOffset ? 0 : start, to = ignoresOffset ? end - start : end
        let slice = from < all.count ? Array(all[from..<min(to, all.count)]) : []
        return GenreAlbumPage(albums: slice, total: all.count)
    }
}

private func album(_ i: Int, year: Int, name: String? = nil, artist: String = "A", plays: Int = 0, starred: Bool = false,
                   added: Double = 0, original: Int? = nil) -> Album {
    Album(id: "al\(i)", name: name ?? String(format: "Album %04d", i), artist: artist, year: year, songCount: 1,
          duration: 1, starred: starred, created: Date(timeIntervalSince1970: added), playCount: plays,
          originalYear: original)
}

@MainActor @Suite struct GenreAlbumsTests {
    /// 1,200 Rock and Indie Rock albums from 1960 to 2019 (20 a year), a few Metal ones.
    private static func bigGroup() -> FakeAlbumServer {
        var rows: [FakeAlbumServer.Row] = []
        for i in 0..<1200 {
            rows.append(.init(album: album(i, year: 1960 + i % 60, plays: i % 7), genres: [i % 3 == 0 ? "Indie Rock" : "Rock"]))
        }
        for i in 1200..<1210 { rows.append(.init(album: album(i, year: 1990), genres: ["Metal"])) }
        return FakeAlbumServer(rows)
    }

    @Test func pagesNeverHoldTheWholeGroup() async throws {
        let server = Self.bigGroup()
        let pager = GenreAlbumPager(source: server, query: GenreAlbumQuery(genres: ["Rock", "Indie Rock"], sort: .name))
        try await pager.loadFirst()
        #expect(pager.albums.count == GenreAlbumPager.pageSize)
        #expect(pager.total == 1200 && pager.hasMore)
        try await pager.loadMore()
        #expect(pager.albums.count == 2 * GenreAlbumPager.pageSize)
        #expect(server.reads.map(\.start) == [0, 100] && server.reads.map(\.end) == [100, 200])
        #expect(pager.albums.map(\.name) == pager.albums.map(\.name).sorted(), "the server's order, page after page")
        while pager.hasMore { try await pager.loadMore() }
        #expect(pager.albums.count == 1200 && Set(pager.albums.map(\.id)).count == 1200)
        #expect(server.reads.count == 12)
    }

    @Test func aShortListIsOnePage() async throws {
        let server = FakeAlbumServer([.init(album: album(1, year: 2000), genres: ["Metal"])])
        let pager = GenreAlbumPager(source: server, query: GenreAlbumQuery(genres: ["Metal"], sort: .newest))
        try await pager.loadFirst()
        #expect(pager.albums.count == 1 && !pager.hasMore && pager.total == 1)
        try await pager.loadMore()
        #expect(server.reads.count == 1, "nothing more is asked")
    }

    @Test func eachSortOrdersTheList() {
        let albums = [album(1, year: 1990, name: "beta", artist: "Zed", plays: 3, added: 10),
                      album(2, year: 2010, name: "Alpha", artist: "Ann", plays: 9, added: 5),
                      album(3, year: 2000, name: "Gamma", artist: "Ann", plays: 1, added: 20)]
        let ids = { (sort: GenreAlbumSort) in GenreAlbumOrder.sorted(albums, by: sort).map(\.id) }
        #expect(ids(.name) == ["al2", "al1", "al3"])
        #expect(ids(.artist) == ["al2", "al3", "al1"])
        #expect(ids(.newest) == ["al2", "al3", "al1"])
        #expect(ids(.oldest) == ["al1", "al3", "al2"])
        #expect(ids(.recentlyAdded) == ["al3", "al1", "al2"])
        #expect(ids(.mostPlayed) == ["al2", "al1", "al3"])
        #expect(GenreAlbumOrder.sorted(albums, by: .random, seed: 7).map(\.id)
                == GenreAlbumOrder.sorted(albums, by: .random, seed: 7).map(\.id), "the same seed, the same order")
    }

    @Test func thePhonesFilterMatchesTextDecadeAndFavourites() {
        let albums = [album(1, year: 1994, name: "Café Nights", artist: "Zed"),
                      album(2, year: 1999, name: "Other", artist: "Éléonore", starred: true),
                      album(3, year: 2003, name: "Late", artist: "Ann", starred: true)]
        let ids = { (f: GenreAlbumFilter) in GenreAlbumOrder.apply(albums, sort: .name, filter: f).map(\.id) }
        #expect(ids(GenreAlbumFilter(text: "  cafe ")) == ["al1"], "accents and case folded, trimmed")
        #expect(ids(GenreAlbumFilter(text: "eleo")) == ["al2"], "the artist too")
        #expect(ids(GenreAlbumFilter(decade: 1990)) == ["al1", "al2"])
        #expect(ids(GenreAlbumFilter(decade: 1990, favouritesOnly: true)) == ["al2"])
        #expect(ids(.none) == ["al1", "al3", "al2"], "nothing filtered, by name")
    }

    @Test func theFiltersSayWhatIsAsked() {
        var f = GenreAlbumFilter.none
        #expect(!f.isActive && f.searchText == nil)
        #expect(f.genres(of: ["Rock", "Indie Rock"]) == ["Rock", "Indie Rock"], "none picked: all of the page's")
        f.genres = ["Indie Rock", "Jazz"]
        #expect(f.genres(of: ["Rock", "Indie Rock"]) == ["Indie Rock"], "only the page's own")
        #expect(f.isActive)
        f = GenreAlbumFilter(text: String(repeating: "x", count: 500))
        #expect(f.searchText?.count == GenreAlbumFilter.maxText)
        #expect(Decades.spanning(oldest: 1964, newest: 2019) == [2010, 2000, 1990, 1980, 1970, 1960])
        #expect(Decades.spanning(oldest: nil, newest: 2003) == [2000])
        #expect(Decades.decade(of: 0) == nil && Decades.label(1990) == "1990s")
    }

    /// A decade (Navidrome filters one exact year only): found by seeks in the year order, then read whole and put in the
    /// chosen order on the phone.
    @Test func aDecadeIsAWindowOfTheYearOrder() async throws {
        let server = Self.bigGroup()
        let query = GenreAlbumQuery(genres: ["Rock", "Indie Rock"], sort: .name)
        let pager = GenreAlbumPager(source: server, query: query, decade: 1990)
        try await pager.loadFirst()
        #expect(pager.albums.count == 200 && pager.total == 200, "20 a year for ten years")
        #expect(pager.albums.allSatisfy { (1990...1999).contains($0.year ?? 0) })
        #expect(pager.albums.map(\.name) == pager.albums.map(\.name).sorted(), "in the chosen order")
        #expect(!pager.hasMore && !pager.inYearOrder)
        #expect(server.reads.allSatisfy { $0.query.sort == .oldest }, "the window is read in year order")
        #expect(server.reads.filter { $0.end - $0.start == 1 }.count <= 2 * 12, "about 2 × log2(1200) seeks")
        #expect(server.reads.filter { $0.end - $0.start > 1 }.reduce(0) { $0 + $1.end - $1.start } == 200,
                "only the decade's albums are read")
    }

    /// The decades a page offers: from its oldest known year to its newest (albums without a year are skipped).
    @Test func theYearSpanSkipsUnknownYears() async throws {
        var rows = (0..<40).map { FakeAlbumServer.Row(album: album($0, year: 1970 + $0), genres: ["G"]) }
        rows += (40..<45).map { FakeAlbumServer.Row(album: album($0, year: 0), genres: ["G"]) }
        let span = try await GenreAlbumPager.yearSpan(FakeAlbumServer(rows), query: GenreAlbumQuery(genres: ["G"], sort: .name))
        #expect(span.oldest == 1970 && span.newest == 2009)
        #expect(Decades.spanning(oldest: span.oldest, newest: span.newest) == [2000, 1990, 1980, 1970])
    }

    @Test func aDecadeWithNothingInItIsEmpty() async throws {
        let pager = GenreAlbumPager(source: Self.bigGroup(), query: GenreAlbumQuery(genres: ["Rock"], sort: .name), decade: 1940)
        try await pager.loadFirst()
        #expect(pager.albums.isEmpty && pager.total == 0 && !pager.hasMore)
    }

    /// A decade too big to sort on the phone is paged in year order: newest first for Newest, else oldest first, and
    /// `inYearOrder` says the chosen order couldn't be kept.
    @Test func aHugeDecadeIsPagedInYearOrder() async throws {
        var rows: [FakeAlbumServer.Row] = []
        for i in 0..<1500 { rows.append(.init(album: album(i, year: 2000 + i % 10), genres: ["Rock"])) }
        for i in 1500..<1520 { rows.append(.init(album: album(i, year: 1999), genres: ["Rock"])) }
        let server = FakeAlbumServer(rows)
        let newest = GenreAlbumPager(source: server, query: GenreAlbumQuery(genres: ["Rock"], sort: .newest), decade: 2000)
        try await newest.loadFirst()
        #expect(newest.total == 1500 && newest.albums.count >= GenreAlbumPager.pageSize && newest.hasMore)
        #expect(newest.albums.count < 400, "a page or so, whole years at a time")
        #expect(!newest.inYearOrder, "Newest is year order")
        #expect(newest.albums.first?.year == 2009)
        while newest.hasMore { try await newest.loadMore() }
        #expect(newest.albums.count == 1500 && newest.albums.last?.year == 2000)
        let years = newest.albums.map { $0.year ?? 0 }
        #expect(years == years.sorted(by: >))

        let byName = GenreAlbumPager(source: server, query: GenreAlbumQuery(genres: ["Rock"], sort: .name), decade: 2000)
        try await byName.loadFirst()
        #expect(byName.inYearOrder && byName.albums.first?.year == 2000)
    }

    /// A short page ends the list; nothing more is asked.
    @Test func aShortPageEndsTheList() async throws {
        let server = FakeAlbumServer((0..<150).map { .init(album: album($0, year: 2000), genres: ["G"]) })
        let pager = GenreAlbumPager(source: server, query: GenreAlbumQuery(genres: ["G"], sort: .name))
        try await pager.loadFirst()
        try await pager.loadMore()
        #expect(pager.albums.count == 150 && !pager.hasMore)
        try await pager.loadMore()
        #expect(server.reads.count == 2)
    }

    /// M4: a server that ignores the offset (every read answers the first page) never loops: a page with nothing new
    /// ends the list.
    @Test func aServerIgnoringTheOffsetNeverLoops() async throws {
        let server = FakeAlbumServer((0..<450).map { .init(album: album($0, year: 2000), genres: ["G"]) }, ignoresOffset: true)
        let pager = GenreAlbumPager(source: server, query: GenreAlbumQuery(genres: ["G"], sort: .name))
        try await pager.loadFirst()
        for _ in 0..<10 where pager.hasMore { try await pager.loadMore() }
        #expect(pager.albums.count == GenreAlbumPager.pageSize && !pager.hasMore)
        #expect(server.reads.count == 2, "the repeat ends it")
    }

    // MARK: - Fix round (review I1, I3, M1, M2)

    /// I1: Navidrome's year order is by the original date first. A 2010 remaster of a 1975 album is in the 1970s; the
    /// decade window, the filter and the order all go by that year, and the count matches the grid.
    @Test func aDecadeGoesByTheOriginalYear() async throws {
        var rows = (0..<300).map { FakeAlbumServer.Row(album: album($0, year: 1950 + $0 % 60), genres: ["G"]) }
        rows.append(.init(album: album(900, year: 2010, name: "Remaster", original: 1975), genres: ["G"]))
        rows.append(.init(album: album(901, year: 1979, name: "Reissue", original: 1969), genres: ["G"]))
        let server = FakeAlbumServer(rows)
        let seventies = GenreAlbumPager(source: server, query: GenreAlbumQuery(genres: ["G"], sort: .oldest), decade: 1970)
        try await seventies.loadFirst()
        let names = seventies.albums.map(\.name)
        #expect(names.contains("Remaster") && !names.contains("Reissue"))
        #expect(seventies.total == seventies.albums.count, "the count matches the grid")
        #expect(seventies.albums.allSatisfy { (1970...1979).contains($0.sortYear ?? 0) })
        let years = seventies.albums.map { $0.sortYear ?? 0 }
        #expect(years == years.sorted(), "Oldest by the year Navidrome orders by")
        let tens = GenreAlbumPager(source: server, query: GenreAlbumQuery(genres: ["G"], sort: .name), decade: 2010)
        try await tens.loadFirst()
        #expect(!tens.albums.map(\.name).contains("Remaster"))
    }

    @Test func thePhonesOrderAndDecadeGoByTheOriginalYear() {
        let albums = [album(1, year: 2010, name: "Remaster", original: 1975), album(2, year: 1990, name: "Plain")]
        #expect(GenreAlbumOrder.sorted(albums, by: .oldest).map(\.id) == ["al1", "al2"])
        #expect(GenreAlbumOrder.apply(albums, sort: .name, filter: GenreAlbumFilter(decade: 1970)).map(\.id) == ["al1"])
    }

    /// I3: Navidrome has no tiebreak after `play_count`, and the unplayed albums are one big tie. Read page by page from a
    /// server that returns ties in a new order on every read, Most played still shows every album once: the played ones
    /// first, most plays first, then the rest by name.
    @Test func mostPlayedHasNoGapsWhenTheServerShufflesTies() async throws {
        var rows: [FakeAlbumServer.Row] = []
        for i in 0..<700 { rows.append(.init(album: album(i, year: 2000, plays: i < 120 ? 1 + i % 4 : 0), genres: ["G"])) }
        let server = FakeAlbumServer(rows, unstableTies: true)
        let pager = GenreAlbumPager(source: server, query: GenreAlbumQuery(genres: ["G"], sort: .mostPlayed))
        try await pager.loadFirst()
        for _ in 0..<50 where pager.hasMore { try await pager.loadMore() }
        #expect(pager.albums.count == 700, "no gaps")
        #expect(Set(pager.albums.map(\.id)).count == 700)
        let plays = pager.albums.map { $0.playCount ?? 0 }
        #expect(plays == plays.sorted(by: >), "most plays first")
        let unplayed = pager.albums.filter { ($0.playCount ?? 0) == 0 }.map(\.name)
        #expect(unplayed == unplayed.sorted(), "then the rest by name")
        #expect(pager.total == 700)
    }

    /// M2: a decade too big to sort on the phone, read newest first, keeps each year's albums in name order.
    @Test func aHugeDecadeNewestFirstKeepsNamesInOrderWithinAYear() async throws {
        let rows = (0..<1500).map { FakeAlbumServer.Row(album: album($0, year: 2000 + $0 % 10), genres: ["G"]) }
        let pager = GenreAlbumPager(source: FakeAlbumServer(rows), query: GenreAlbumQuery(genres: ["G"], sort: .newest),
                                    decade: 2000)
        try await pager.loadFirst()
        while pager.hasMore { try await pager.loadMore() }
        #expect(pager.albums.count == 1500)
        for year in 2000...2009 {
            let names = pager.albums.filter { $0.year == year }.map(\.name)
            #expect(names == names.sorted(), "\(year): A to Z")
        }
        let years = pager.albums.map { $0.year ?? 0 }
        #expect(years == years.sorted(by: >))
    }

    // MARK: - The sort is kept (D143)

    @Test func theLastSortIsKeptPerScreen() {
        var prefs = GenrePreferences.defaultValue
        #expect(prefs.groupSort == .name && prefs.genreSort == .name)
        prefs.groupSort = .recentlyAdded
        prefs.genreSort = .random
        let stored = try! JSONEncoder().encode(prefs)
        let back = GenrePreferences.decode(stored)
        #expect(back.groupSort == .recentlyAdded && back.genreSort == .random)
        // Saved by an older build (no sort keys) or with a value this build doesn't know: Name, the rest kept.
        let old = Data(#"{"mode":"all","assignments":{},"groupNames":{},"hidden":[],"customGroups":[],"groupSort":"loudest"}"#.utf8)
        let decoded = GenrePreferences.decode(old)
        #expect(decoded.mode == .all && decoded.groupSort == .name && decoded.genreSort == .name)
    }
}
