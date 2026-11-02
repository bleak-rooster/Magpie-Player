import Foundation
import MagpieCore
import Testing
@testable import Search

/// Y1 (plan items 1 and 3): the library half of search against a fake server with Navidrome's AND-word semantics:
/// split queries, the concurrency cap, and paging with search3 offsets.
@Suite struct LibraryPagerTests {
    private func pager(_ server: FakeNavidrome, maxConcurrent: Int = LibraryPager.maxConcurrent) -> LibraryPager {
        LibraryPager(maxConcurrent: maxConcurrent) { try await server.search($0) }
    }

    private func many(_ n: Int) -> FakeNavidrome {
        let songs = (0..<n).map { Fixture.song(String(format: "m%03d", $0), "Harbour \($0)", "Corin Hale", "Saltwater") }
        let albums = (0..<n).map { Album(id: String(format: "a%03d", $0), name: "Harbour \($0)", artist: "Corin Hale", songCount: 1, duration: 1) }
        let artists = (0..<n).map { Artist(id: String(format: "r%03d", $0), name: "Harbour \($0)", albumCount: 1) }
        return FakeNavidrome(LibrarySearchResult(songs: songs, albums: albums, artists: artists))
    }

    // MARK: - Split queries

    /// AND-word semantics can't find "hey jude" by a misspelt artist; the split "hey jude" + "beatels" does, and keeps
    /// only songs and albums whose artist matches.
    @Test func splitFindsWhatTheWholeQueryMisses() async throws {
        let server = FakeNavidrome()
        let (found, paging) = try await pager(server).first("hey jude beatels")
        #expect(found.songs.map(\.id).sorted() == ["s02", "s04"], "Wilson Pickett's Hey Jude is filtered out")
        #expect(Set(server.queries.map(\.text)) == ["hey jude beatels", "hey jude", "jude beatels", "hey", "beatels"])
        #expect(server.queries.count == 5, "the whole query and four splits")
        #expect(paging.query == "hey jude beatels")
        let s = SearchSections.library(found, query: "hey jude beatels")
        if case .song(let top) = s.top { #expect(top.id == "s04") } else { Issue.record("top is not a song: \(String(describing: s.top))") }
    }

    @Test func splitsAskForSongsAndAlbumsOnly() async throws {
        let server = FakeNavidrome()
        _ = try await pager(server).first("bloodbuzz national")
        let splits = server.queries.filter { $0.text != "bloodbuzz national" }
        #expect(splits.count == 2)
        #expect(splits.allSatisfy { $0.artistCount == 0 && $0.songCount == 20 && $0.albumCount == 10 })
        let whole = try #require(server.queries.first { $0.text == "bloodbuzz national" })
        #expect(whole.songCount == 20 && whole.albumCount == 10 && whole.artistCount == 10)
    }

    @Test func separatorQueriesDontGuess() async throws {
        let server = FakeNavidrome()
        let (found, _) = try await pager(server).first("skinny love by bon iver")
        #expect(Set(server.queries.map(\.text)) == ["skinny love by bon iver", "skinny love"])
        #expect(found.songs.map(\.id) == ["s19"])
    }

    @Test func noDuplicatesAcrossTheWholeQueryAndSplits() async throws {
        let server = FakeNavidrome()
        let (found, paging) = try await pager(server).first("hey jude beatles")
        #expect(found.songs.count == Set(found.songs.map(\.id)).count)
        #expect(found.albums.count == Set(found.albums.map(\.id)).count)
        #expect(paging.seen(.songs) == Set(found.songs.map(\.id)))
    }

    @Test func atMostThreeRequestsRunAtOnce() async throws {
        let server = FakeNavidrome()
        server.delay = .milliseconds(20)
        _ = try await pager(server).first("hey jude beatles")
        #expect(server.queries.count == 5)
        #expect(server.peak <= LibraryPager.maxConcurrent && LibraryPager.maxConcurrent == 3)
        #expect(server.peak >= 2, "they do run in parallel")
    }

    /// A failed split adds nothing; only the whole query failing (with nothing from the splits) is an error.
    @Test func failures() async throws {
        let server = FakeNavidrome()
        server.failing = ["hey jude"]
        let (found, _) = try await pager(server).first("hey jude beatles")
        #expect(Set(found.songs.map(\.id)) == ["s02", "s04"], "the whole query still finds them")

        let broken = FakeNavidrome()
        broken.failing = ["hey jude beatels", "hey jude", "hey", "jude beatels", "beatels"]
        await #expect(throws: URLError.self) { _ = try await pager(broken).first("hey jude beatels") }

        let wholeOnly = FakeNavidrome()
        wholeOnly.failing = ["hey jude beatels"]
        let (fromSplits, paging) = try await pager(wholeOnly).first("hey jude beatels")
        #expect(fromSplits.songs.map(\.id).sorted() == ["s02", "s04"])
        #expect(!paging.hasMore(.artists), "the whole query failed, so it can't page")
    }

    // MARK: - Paging

    @Test func pagesWithOffsetsUntilAShortBatch() async throws {
        let server = many(45)
        let p = pager(server)
        let (found, paging0) = try await p.first("harbour")
        #expect(found.songs.count == 20 && found.albums.count == 10 && found.artists.count == 10)
        #expect(paging0.hasMore(.songs) && paging0.hasMore(.albums) && paging0.hasMore(.artists))

        let more1 = try await p.more(.songs, paging: paging0)
        #expect(more1.songs.map(\.id) == (20..<40).map { String(format: "m%03d", $0) })
        #expect(more1.albums.isEmpty && more1.artists.isEmpty)
        let last = try #require(server.queries.last)
        #expect(last.songOffset == 20 && last.songCount == 20 && last.albumCount == 0 && last.artistCount == 0)
        #expect(more1.paging.hasMore(.songs))

        let more2 = try await p.more(.songs, paging: more1.paging)
        #expect(more2.songs.count == 5, "a short batch")
        #expect(!more2.paging.hasMore(.songs), "a short batch ends the section")
        #expect(more2.paging.hasMore(.albums), "other sections page on their own")

        let albums = try await p.more(.albums, paging: more2.paging)
        #expect(albums.albums.map(\.id) == (10..<20).map { String(format: "a%03d", $0) })
        #expect(server.queries.last?.albumOffset == 10)
        let artists = try await p.more(.artists, paging: albums.paging)
        #expect(artists.artists.first?.id == "r010" && server.queries.last?.artistOffset == 10)
    }

    @Test func aFirstShortBatchHasNoMore() async throws {
        let (_, paging) = try await pager(FakeNavidrome()).first("bloodbuzz")
        #expect(!paging.hasMore(.songs) && !paging.hasMore(.albums) && !paging.hasMore(.artists))
    }

    /// Rows already shown (from another query of the plan, or an earlier batch) are never shown again.
    @Test func noDuplicatesAcrossBatches() async throws {
        let server = many(30)
        let p = pager(server)
        let (found, paging) = try await p.first("harbour corin")   // whole + splits all find the same songs
        let more = try await p.more(.songs, paging: paging)
        let all = found.songs.map(\.id) + more.songs.map(\.id)
        #expect(all.count == Set(all).count)
        #expect(Set(all).count == 30)
        #expect(more.paging.seen(.songs) == Set(all))
    }

    /// Split queries page too: each keeps its own offset.
    @Test func splitQueriesPage() async throws {
        let server = many(30)
        let p = pager(server)
        let (_, paging) = try await p.first("harbour corin")
        let before = server.queries.count
        _ = try await p.more(.songs, paging: paging)
        let round = server.queries.dropFirst(before)
        #expect(Set(round.map(\.text)) == ["harbour corin", "harbour", "corin"])
        #expect(round.allSatisfy { $0.songOffset == 20 })
    }

    /// A load-more running when the query changes is cancelled: it throws and asks for nothing more.
    @Test func cancellation() async throws {
        let server = many(100)
        let p = pager(server)
        let (_, paging) = try await p.first("harbour")
        server.delay = .seconds(30)
        let task = Task { try await p.more(.songs, paging: paging) }
        for _ in 0..<10_000 where server.queries.count < 2 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(server.queries.count == 2)
    }

    /// Batches whose rows a split's artist filter drops entirely don't stop the load: it keeps going (within a limit)
    /// until something new comes, so the footer never waits for nothing.
    @Test func filteredOutBatchesKeepLoading() async throws {
        var songs = (0..<60).map { Fixture.song(String(format: "x%03d", $0), "Love \($0)", "Someone Else", "Other") }
        songs.append(Fixture.song("b1", "Love Me Do", "The Beatles", "Please Please Me"))
        let server = FakeNavidrome(LibrarySearchResult(songs: songs))
        let p = pager(server)
        let (found, paging) = try await p.first("love beatls")   // the misspelt whole query finds nothing
        #expect(found.songs.isEmpty)
        let more = try await p.more(.songs, paging: paging)
        #expect(more.songs.map(\.id) == ["b1"])
        #expect(!more.paging.hasMore(.songs))
    }
}
