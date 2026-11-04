import Foundation
import MagpieCore
import os
import Search
import Testing
@testable import Magpie

/// Round 14 A5 (D98): the "Not in your library" band pages too. A tap on its More loads the kind's next page (one at a
/// time), a failed page offers to try again, and a page for an old query is dropped.
@MainActor
@Suite struct SearchOutsideMoreTests {
    let sleeper = ManualSleeper()

    final class Pages: @unchecked Sendable {
        let flags = OSAllocatedUnfairLock(initialState: (fail: false, calls: 0))
        var fail: Bool { get { flags.withLock { $0.fail } } set { flags.withLock { $0.fail = newValue } } }
        var calls: Int { flags.withLock { $0.calls } }
        func page(_ q: String, _ offset: Int) throws -> (items: [NotYetArtist], next: Int?) {
            let fail = flags.withLock { $0.calls += 1; return $0.fail }
            if fail { throw URLError(.timedOut) }
            return ((offset..<offset + 5).map { NotYetArtist(name: "\(q) \($0)") }, offset + 5 < 15 ? offset + 5 : nil)
        }
    }

    func makeModel(_ pages: Pages) -> SearchModel {
        let source = MergedSearch.Source(timeout: .seconds(5)) { q in
            ExternalHits(artists: (0..<5).map { NotYetArtist(name: "\(q) \($0)") }, cursor: OutsideCursor(aurralArtistsOffset: 5))
        }
        let search = MergedSearch(library: { _ in LibrarySearchResult() }, sources: [source],
                                  outsideMore: MergedSearch.OutsideMore(artists: { try pages.page($0, $1) }),
                                  index: { .empty })
        let sleeper = self.sleeper
        return SearchModel(search: { q, early in try await search.runReportingLibraryFailure(q, libraryFirst: early) },
                           outsideMore: { kind, sections in try await search.moreOutside(kind, in: sections) },
                           sleep: { try await sleeper.sleep($0) })
    }

    func searched(_ model: SearchModel, _ q: String) async {
        model.update(query: q)
        for _ in 0..<1000 where sleeper.waiting == 0 { await Task.yield() }
        sleeper.releaseAll()
        await model.settle()
    }

    @Test func moreAddsTheNextPageUntilThereIsNoMore() async {
        let pages = Pages()
        let model = makeModel(pages)
        await searched(model, "arrow")
        #expect(model.results.notYet.artists.count == 5)
        #expect(model.results.hasMoreOutside(.artists))
        model.loadMoreOutside(.artists)
        #expect(model.outsideMoreState(.artists) == .loading)
        model.loadMoreOutside(.artists)   // one at a time
        await model.settleMore()
        #expect(model.results.notYet.artists.count == 10)
        model.loadMoreOutside(.artists)
        await model.settleMore()
        #expect(model.results.notYet.artists.count == 15)
        #expect(!model.results.hasMoreOutside(.artists))
        #expect(pages.calls == 2)
    }

    @Test func aFailedPageOffersToTryAgain() async {
        let pages = Pages()
        pages.fail = true
        let model = makeModel(pages)
        await searched(model, "arrow")
        model.loadMoreOutside(.artists)
        await model.settleMore()
        #expect(model.outsideMoreState(.artists) == .failed)
        #expect(model.results.notYet.artists.count == 5)
        pages.fail = false
        model.loadMoreOutside(.artists)
        await model.settleMore()
        #expect(model.outsideMoreState(.artists) == .idle)
        #expect(model.results.notYet.artists.count == 10)
    }

    @Test func aPageForAnOldQueryIsDropped() async {
        let pages = Pages()
        let model = makeModel(pages)
        await searched(model, "arrow")
        model.loadMoreOutside(.artists)
        model.update(query: "bow")
        await model.settleMore()
        #expect(model.results.notYet.artists.isEmpty)
        #expect(model.outsideMoreState(.artists) == .idle)
    }
}
