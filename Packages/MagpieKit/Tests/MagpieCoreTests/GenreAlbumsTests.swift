import Foundation
import os
import Testing
@testable import MagpieCore

/// A stand-in for Navidrome's `/api/album`: sorts and filters `albums` (each tagged with genres) as the server does and
/// notes every read.
private final class FakeAlbumServer: GenreAlbumSource, @unchecked Sendable {
    struct Row { var album: Album; var genres: Set<String> }
    let rows: [Row]
    private let lock = OSAllocatedUnfairLock(initialState: [(GenreAlbumQuery, Int, Int)]())
    init(_ rows: [Row]) { self.rows = rows }
    var reads: [(query: GenreAlbumQuery, start: Int, end: Int)] { lock.withLock { $0.map { ($0.0, $0.1, $0.2) } } }

    func page(_ query: GenreAlbumQuery, start: Int, end: Int) async throws -> GenreAlbumPage {
        lock.withLock { $0.append((query, start, end)) }
        let wanted = Set(query.genres)
        let filter = GenreAlbumFilter(text: query.text ?? "", favouritesOnly: query.favouritesOnly)
        let matching = rows.filter { !$0.genres.isDisjoint(with: wanted) }.map(\.album)
        let all = GenreAlbumOrder.apply(matching, sort: query.sort, filter: filter, seed: query.seed)
        let slice = start < all.count ? Array(all[start..<min(end, all.count)]) : []
        return GenreAlbumPage(albums: slice, total: all.count)
    }
}

private func album(_ i: Int, year: Int, name: String? = nil, artist: String = "A", plays: Int = 0, starred: Bool = false,
                   added: Double = 0) -> Album {
    Album(id: "al\(i)", name: name ?? String(format: "Album %04d", i), artist: artist, year: year, songCount: 1,
          duration: 1, starred: starred, created: Date(timeIntervalSince1970: added), playCount: plays)
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
        #expect(newest.total == 1500 && newest.albums.count == GenreAlbumPager.pageSize && newest.hasMore)
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

    /// A server that ignores the offset (every read the same page) never loops: nothing new ends the list.
    @Test func repeatsAreDroppedAndAShortPageEnds() async throws {
        let server = FakeAlbumServer((0..<150).map { .init(album: album($0, year: 2000), genres: ["G"]) })
        let pager = GenreAlbumPager(source: server, query: GenreAlbumQuery(genres: ["G"], sort: .name))
        try await pager.loadFirst()
        try await pager.loadMore()
        #expect(pager.albums.count == 150 && !pager.hasMore)
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
