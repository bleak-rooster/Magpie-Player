import MagpieCore
import Search
import SwiftUI

/// One read of a server-paged list: the items from `offset`, where the next read starts, and whether that was the end.
struct PagedRead<Item> {
    var items: [Item]
    var next: Int
    var end: Bool
}

/// A server-paged A–Z list (Library › Songs and Albums) as a window of server offsets, so the letter index (P2) can
/// jump anywhere without reading everything before it:
/// - a letter already loaded scrolls there;
/// - otherwise the server's sort is searched for the letter's first offset (`LetterIndex.seek`): a few pages ahead
///   pages forward; further, or before the window, loads from that offset, with "Show earlier" at the top.
@MainActor @Observable final class PagedLetterList<Item> {
    private(set) var items: Loadable<[Item]> = .loading
    /// The server offset of the first loaded item, and of the next read.
    private(set) var windowStart = 0
    private(set) var windowEnd = 0
    private(set) var exhausted = false
    private(set) var loadingMore = false
    private(set) var loadingEarlier = false
    private(set) var moreError: String?
    /// A letter is being looked for on the server.
    private(set) var seeking = false
    /// The item to scroll to (with a token, so the same item can be asked for twice).
    private(set) var scrollRequest: ScrollRequest?

    struct ScrollRequest: Equatable {
        var id: String
        var token: Int
    }

    let pageSize: Int
    /// The articles the server's sort drops (artists and albums), so sections match its order.
    let articles: [String]
    @ObservationIgnored private let name: (Item) -> String
    @ObservationIgnored private let id: (Item) -> String
    @ObservationIgnored private let read: (Int) async throws -> PagedRead<Item>
    @ObservationIgnored private let seek: (String) async throws -> Int
    /// Bumped when the window starts again, so a read still in flight for the old window is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tokens = 0

    init(pageSize: Int, articles: [String] = [], name: @escaping (Item) -> String, id: @escaping (Item) -> String,
         read: @escaping (Int) async throws -> PagedRead<Item>, seek: @escaping (String) async throws -> Int) {
        self.pageSize = pageSize; self.articles = articles
        self.name = name; self.id = id; self.read = read; self.seek = seek
    }

    /// The loaded items' runs of one letter.
    var sections: [LetterIndex.Section] {
        LetterIndex.sections(items.value ?? [], ignoringArticles: articles, name: name)
    }

    /// Letters the index shows in full: all of them until the list is known to the end, then the ones it has.
    var availableLetters: Set<String> {
        exhausted && windowStart == 0 ? Set(sections.map(\.key)) : Set(LetterIndex.letters)
    }

    /// Loads the window from `offset` (0: the top of the list).
    func load(from offset: Int = 0) async {
        generation += 1
        let mine = generation
        do {
            let page = try await read(offset)
            guard mine == generation else { return }
            windowStart = offset
            windowEnd = page.next
            exhausted = page.end
            moreError = nil
            items = .loaded(dedupe(page.items))
        } catch {
            guard mine == generation else { return }
            if items.value == nil || offset == 0 { items = .failed(BrowseErrorCopy.message(for: error)) }
            else { moreError = BrowseErrorCopy.message(for: error) }
        }
    }

    /// The next page, when the last row appears.
    func loadMore() async {
        guard !exhausted, !loadingMore, let current = items.value else { return }
        let mine = generation
        loadingMore = true
        moreError = nil
        defer { loadingMore = false }
        do {
            let page = try await read(windowEnd)
            guard mine == generation else { return }
            windowEnd = page.next
            exhausted = page.end
            let known = Set(current.map(id))
            items = .loaded(current + page.items.filter { !known.contains(id($0)) })
        } catch {
            guard mine == generation else { return }
            moreError = BrowseErrorCopy.message(for: error)
        }
    }

    /// The page before the window ("Show earlier"), keeping the first row in view.
    func loadEarlier() async {
        guard windowStart > 0, !loadingEarlier, let current = items.value, let first = current.first else { return }
        let mine = generation
        loadingEarlier = true
        defer { loadingEarlier = false }
        let start = max(0, windowStart - pageSize)
        guard let page = try? await read(start), mine == generation else { return }
        let known = Set(current.map(id))
        // Only rows before the window: a page read from `start` can run past `windowStart`.
        let before = page.items.prefix(max(0, windowStart - start)).filter { !known.contains(id($0)) }
        windowStart = start
        items = .loaded(Array(before) + current)
        scroll(to: first)
    }

    /// The letter index picked `letter`.
    func jump(to letter: String) async {
        guard let current = items.value, !current.isEmpty, !seeking else { return }
        if let i = LetterIndex.loadedTarget(letter, sections: sections, windowStart: windowStart, complete: exhausted) {
            return scroll(to: current[i])
        }
        seeking = true
        defer { seeking = false }
        guard let offset = try? await seek(letter) else { return }
        switch LetterIndex.move(toOffset: offset, windowStart: windowStart, windowEnd: windowEnd,
                                forwardLimit: pageSize * 3) {
        case .scroll(let n):
            scrollNear(n, letter: letter)
        case .pageForward(let target):
            for _ in 0..<5 where windowEnd <= target && !exhausted && moreError == nil {
                if loadingMore { try? await Task.sleep(for: .milliseconds(50)) } else { await loadMore() }
            }
            scrollNear(target - windowStart, letter: letter)
        case .restart(let target):
            if exhausted, windowStart == 0, target >= windowEnd, let last = current.last { return scroll(to: last) }
            await load(from: target)
            if let first = items.value?.first { scroll(to: first) }
        }
    }

    /// The letter's first loaded run when it has one, else about `n` rows into the window.
    private func scrollNear(_ n: Int, letter: String) {
        guard let current = items.value, !current.isEmpty else { return }
        if let i = LetterIndex.loadedTarget(letter, sections: sections, windowStart: windowStart, complete: false) {
            return scroll(to: current[i])
        }
        scroll(to: current[min(max(n, 0), current.count - 1)])
    }

    private func scroll(to item: Item) {
        tokens += 1
        scrollRequest = ScrollRequest(id: id(item), token: tokens)
    }

    private func dedupe(_ list: [Item]) -> [Item] {
        var seen = Set<String>()
        return list.filter { seen.insert(id($0)).inserted }
    }
}
