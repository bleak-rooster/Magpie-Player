import Foundation
import MagpieCore
import os
import Search
import Testing
@testable import Magpie

/// A library of `n` songs called "Harbour <i>" behind a search3-like page function: counts and offsets slice it, and
/// every call is recorded. Batches after the first can be held at a gate or made to fail.
final class PagedLibrary: @unchecked Sendable {
    let songs: [Song]
    private let state = OSAllocatedUnfairLock(initialState: [LibraryQuery]())
    private let flags = OSAllocatedUnfairLock(initialState: (hold: false, fail: false))
    let gate = ManualSleeper()

    init(_ n: Int) {
        songs = (0..<n).map { Song(id: String(format: "h%03d", $0), title: "Harbour \($0)", artist: "Corin Hale",
                                   album: "Saltwater", duration: 100) }
    }

    var calls: [LibraryQuery] { state.withLock { $0 } }
    var holdMore: Bool { get { flags.withLock { $0.hold } } set { flags.withLock { $0.hold = newValue } } }
    var failMore: Bool { get { flags.withLock { $0.fail } } set { flags.withLock { $0.fail = newValue } } }

    func page(_ q: LibraryQuery) async throws -> LibrarySearchResult {
        state.withLock { $0.append(q) }
        if q.songOffset > 0 {
            if holdMore { try await gate.sleep(.seconds(5)) }
            if failMore { throw URLError(.timedOut) }
        }
        let hits = q.text.lowercased().contains("harbour") ? songs : []
        let start = min(q.songOffset, hits.count)
        return LibrarySearchResult(songs: Array(hits[start..<min(hits.count, start + q.songCount)]))
    }
}

/// Y1 (plan item 3): Search loads the next batch of a section at its end, says when there's no more, and drops a
/// load that belongs to an old query.
@MainActor
@Suite struct SearchLoadMoreTests {
    let sleeper = ManualSleeper()

    func makeModel(_ library: PagedLibrary) -> SearchModel {
        let search = MergedSearch(libraryPage: { try await library.page($0) }, sources: [], index: { .empty })
        let sleeper = self.sleeper
        return SearchModel(search: { q, early in try await search.runReportingLibraryFailure(q, libraryFirst: early) },
                           more: { kind, paging in try await search.more(kind, paging: paging) },
                           sleep: { try await sleeper.sleep($0) })
    }

    func searched(_ model: SearchModel, _ q: String) async {
        model.update(query: q)
        for _ in 0..<1000 where sleeper.waiting == 0 { await Task.yield() }
        sleeper.releaseAll()
        await model.settle()
    }

    @Test func loadsTheNextBatchThenSaysNoMore() async {
        let library = PagedLibrary(26)
        let model = makeModel(library)
        await searched(model, "harbour")
        #expect(model.results.songs.count == 20)
        #expect(model.results.hasMore(.songs))
        #expect(model.moreState(.songs) == .idle)

        model.loadMore(.songs)
        #expect(model.moreState(.songs) == .loading)
        await model.settleMore()
        #expect(model.results.songs.count == 26)
        #expect(Set(model.results.songs.map(\.id)).count == 26, "no duplicates")
        #expect(!model.results.hasMore(.songs) && model.results.loadedMore(.songs))
        #expect(model.moreState(.songs) == .idle)
        #expect(library.calls.last?.songOffset == 20)

        let calls = library.calls.count
        model.loadMore(.songs)
        await model.settleMore()
        #expect(library.calls.count == calls, "nothing more is asked for once a batch came back short")
    }

    /// The query changes while a batch is loading: the load is cancelled and its rows never land in the new results.
    @Test func aNewQueryCancelsTheLoad() async {
        let library = PagedLibrary(60)
        library.holdMore = true
        let model = makeModel(library)
        await searched(model, "harbour")
        model.loadMore(.songs)
        for _ in 0..<1000 where library.gate.waiting == 0 { await Task.yield() }
        #expect(library.gate.waiting == 1)

        model.update(query: "zebra")
        #expect(model.results.isEmpty)
        #expect(model.moreState(.songs) == .idle)
        for _ in 0..<1000 where library.gate.waiting > 0 { await Task.yield() }
        #expect(library.gate.waiting == 0, "the held request was cancelled")
        await model.settleMore()
        #expect(model.results.isEmpty, "the old query's batch never lands")
    }

    @Test func aFailedLoadKeepsTheRowsAndCanBeTriedAgain() async {
        let library = PagedLibrary(26)
        library.failMore = true
        let model = makeModel(library)
        await searched(model, "harbour")
        model.loadMore(.songs)
        await model.settleMore()
        #expect(model.moreState(.songs) == .failed)
        #expect(model.results.songs.count == 20 && model.results.hasMore(.songs))

        library.failMore = false
        model.loadMore(.songs)
        await model.settleMore()
        #expect(model.results.songs.count == 26 && model.moreState(.songs) == .idle)
    }

    /// Results without paging (offline) never load more.
    @Test func noPagingNoLoad() async {
        let sleeper = self.sleeper
        let model = SearchModel(
            search: { q, _ in
                .library(LibrarySearchResult(songs: [Song(id: "s", title: "Harbour", artist: "A", album: "B", duration: 1)]),
                         query: q)
            },
            more: { kind, paging in
                Issue.record("asked for more")
                return MoreResults(kind: kind, paging: paging)
            },
            sleep: { try await sleeper.sleep($0) })
        await searched(model, "harbour")
        model.loadMore(.songs)
        await model.settleMore()
        #expect(model.moreState(.songs) == .idle && model.results.songs.count == 1)
    }
}
