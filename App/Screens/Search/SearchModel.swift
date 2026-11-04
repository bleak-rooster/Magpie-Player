import Foundation
import MagpieCore
import Observation
import Search

/// Search as you type (library first, then "Not in your library"): waits for a pause, cancels
/// whatever was in flight, and ignores stale answers. The search call and the sleep are injected so
/// tests run without real time.
@MainActor @Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle          // no query
        case searching
        case done
        case failed(String)
    }

    static let debounce: Duration = .milliseconds(250)

    private(set) var query = ""
    private(set) var results = SearchSections.empty
    private(set) var phase = Phase.idle

    /// The sections for a query. It may hand over library-only sections early (`early`), before the
    /// "Not in your library" band is ready; it throws only when there is nothing to show because the
    /// library search failed (`MergedSearch.runReportingLibraryFailure`).
    typealias Search = @Sendable (_ query: String, _ early: @escaping @Sendable (SearchSections) async -> Void)
        async throws -> SearchSections

    /// The next batch of one library section (round 12, plan item 3).
    typealias More = @Sendable (LibraryKind, SearchPaging) async throws -> MoreResults

    /// Round 14 (D98): the next page of one kind of row in the "Not in your library" band.
    typealias OutsideMore = @Sendable (OutsideKind, SearchSections) async throws -> OutsideMoreResults

    /// A section's load-more: none running, one running, or the last one failed (the footer offers to try again).
    enum MoreState: Equatable { case idle, loading, failed }

    @ObservationIgnored private let search: Search
    @ObservationIgnored private let more: More?
    @ObservationIgnored private let outsideMore: OutsideMore?
    @ObservationIgnored private var outsideTasks: [OutsideKind: Task<Void, Never>] = [:]
    private var outsideStates: [OutsideKind: MoreState] = [:]
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let errorMessage: (Error) -> String
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var moreTasks: [LibraryKind: Task<Void, Never>] = [:]
    private var moreStates: [LibraryKind: MoreState] = [:]
    /// R15: artwork for the "Not in your library" rows, held for the current results only. Every new search drops it
    /// and cancels its fetches, so it's fetched again.
    @ObservationIgnored var outsideArt: OutsideArtLoader?

    init(search: @escaping Search,
         more: More? = nil,
         outsideMore: OutsideMore? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         debounce: Duration = SearchModel.debounce,
         errorMessage: @escaping (Error) -> String = { _ in "Search didn't work. Try again in a moment." }) {
        self.search = search
        self.more = more
        self.outsideMore = outsideMore
        self.sleep = sleep
        self.debounce = debounce
        self.errorMessage = errorMessage
    }

    func moreState(_ kind: LibraryKind) -> MoreState { moreStates[kind] ?? .idle }

    // MARK: - Late rows without jumps (fix round 2)

    /// The library parts of the results, in screen order.
    enum ResultSection: Int, Comparable {
        case top, songs, artists, albums
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Row indexes on screen, per part.
    @ObservationIgnored private var visibleRows: [ResultSection: Set<Int>] = [:]

    func rowAppeared(_ section: ResultSection, index: Int) { visibleRows[section, default: []].insert(index) }
    func rowDisappeared(_ section: ResultSection, index: Int) { visibleRows[section]?.remove(index) }

    /// The first row on screen, if any.
    private var firstVisible: (ResultSection, Int)? {
        visibleRows.compactMap { kv in kv.value.min().map { (kv.key, $0) } }
            .min { ($0.0.rawValue, $0.1) < ($1.0.rawValue, $1.1) }
    }

    /// New results (the splits landing after the whole query's rows) without moving what the user scrolled past:
    /// every row above the first one on screen keeps its place, in its section; the rest take the new order.
    static func stabilised(_ new: SearchSections, old: SearchSections,
                           firstVisible: (ResultSection, Int)?) -> SearchSections {
        guard let (section, index) = firstVisible, !old.libraryIsEmpty else { return new }
        func kept(_ s: ResultSection) -> Int { s < section ? Int.max : s == section ? index : 0 }
        func merge<T>(_ old: [T], _ new: [T], _ s: ResultSection, _ id: (T) -> String) -> [T] {
            let head = Array(old.prefix(kept(s)))
            let ids = Set(head.map(id))
            return head + new.filter { !ids.contains(id($0)) }
        }
        var out = new
        if section > .top { out.top = old.top }
        out.songs = merge(old.songs, new.songs, .songs, \.id)
        out.artists = merge(old.artists, new.artists, .artists, \.id)
        out.albums = merge(old.albums, new.albums, .albums, \.id)
        return out
    }

    // MARK: - When to load more (fix round 1, review I1)

    /// Section ends (footers) on screen.
    @ObservationIgnored private var visibleFooters: Set<LibraryKind> = []
    /// The user has scrolled since the last load (or since the results came). Each load needs a scroll of its own, so
    /// a footer already on screen when results arrive, or still on screen after a batch, loads nothing by itself.
    @ObservationIgnored private var scrolled = false

    /// A section's footer came on screen: loads it if the user brought it there by scrolling.
    func footerAppeared(_ kind: LibraryKind) {
        visibleFooters.insert(kind)
        if scrolled { loadMore(kind) }
    }

    func footerDisappeared(_ kind: LibraryKind) { visibleFooters.remove(kind) }

    /// The user started scrolling the results: every footer on screen loads.
    func userScrolled() {
        scrolled = true
        for kind in visibleFooters { loadMore(kind) }
    }

    /// The end of a section came on screen: loads its next batch, once at a time per section, when the search is
    /// done and the section has more. The rows are added at the end; nothing on screen moves.
    func loadMore(_ kind: LibraryKind) {
        guard phase == .done, let more, let paging = results.paging, results.hasMore(kind),
              moreState(kind) != .loading else { return }
        moreStates[kind] = .loading
        let q = query
        moreTasks[kind] = Task { [weak self] in
            do {
                let found = try await more(kind, paging)
                try Task.checkCancellation()
                self?.finishMore(found, for: q)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.failMore(kind, for: q)
            }
        }
    }

    /// Waits for every running load-more (tests).
    func settleMore() async {
        for task in moreTasks.values { await task.value }
        for task in outsideTasks.values { await task.value }
    }

    // MARK: - The band's Load more (round 14, D98)

    func outsideMoreState(_ kind: OutsideKind) -> MoreState { outsideStates[kind] ?? .idle }

    /// The band's More for one kind was tapped: its next page, one at a time, added at the end (nothing on screen
    /// moves). Only on a tap: an outside page can mean MusicBrainz reads, which are rationed.
    func loadMoreOutside(_ kind: OutsideKind) {
        guard phase == .done, let outsideMore, results.hasMoreOutside(kind), outsideMoreState(kind) != .loading else { return }
        outsideStates[kind] = .loading
        let q = query, snapshot = results
        outsideTasks[kind] = Task { [weak self] in
            do {
                let found = try await outsideMore(kind, snapshot)
                try Task.checkCancellation()
                self?.finishOutside(found, for: q)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.failOutside(kind, for: q)
            }
        }
    }

    private func finishOutside(_ found: OutsideMoreResults, for q: String) {
        guard q == query, phase == .done else { return }
        results.append(found)
        outsideStates[found.kind] = .idle
        outsideTasks[found.kind] = nil
    }

    private func failOutside(_ kind: OutsideKind, for q: String) {
        guard q == query else { return }
        outsideStates[kind] = .failed
        outsideTasks[kind] = nil
    }

    private func finishMore(_ found: MoreResults, for q: String) {
        guard q == query, phase == .done else { return }
        results.append(found)
        moreStates[found.kind] = .idle
        moreTasks[found.kind] = nil
        scrolled = false   // the next batch waits for the next scroll
    }

    private func failMore(_ kind: LibraryKind, for q: String) {
        guard q == query else { return }
        moreStates[kind] = .failed
        moreTasks[kind] = nil
    }

    /// The query changed. Results for the previous query are cleared at once (they would be tappable
    /// and wrong while the new search runs); an empty (or blank) query goes back to idle.
    func update(query newQuery: String) {
        query = newQuery
        task?.cancel()
        moreTasks.values.forEach { $0.cancel() }
        moreStates = [:]
        outsideTasks.values.forEach { $0.cancel() }
        outsideStates = [:]
        scrolled = false
        visibleRows = [:]
        outsideArt?.reset()
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            task = nil
            results = .empty
            phase = .idle
            return
        }
        results = .empty
        phase = .searching
        let search = self.search, sleep = self.sleep, debounce = self.debounce
        task = Task { [weak self] in
            do {
                try await sleep(debounce)
                try Task.checkCancellation()
                let found = try await search(trimmed) { [weak self] early in
                    await self?.showEarly(early, for: newQuery)
                }
                try Task.checkCancellation()
                self?.finish(found, for: newQuery)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.fail(self.errorMessage(error), for: newQuery)
            }
        }
    }

    /// Waits for the current query's search to finish (tests).
    func settle() async {
        await task?.value
    }

    /// Library rows (possibly none) while the outside sources are still out. Still `.searching`.
    private func showEarly(_ sections: SearchSections, for q: String) {
        guard q == query, phase == .searching else { return }
        results = Self.stabilised(sections, old: results, firstVisible: firstVisible)
    }

    private func finish(_ sections: SearchSections, for q: String) {
        guard q == query else { return }
        results = Self.stabilised(sections, old: results, firstVisible: firstVisible)
        phase = .done
    }

    private func fail(_ message: String, for q: String) {
        guard q == query else { return }
        results = .empty
        phase = .failed(message)
    }
}

/// Recent searches, newest first, kept on the device.
struct RecentSearches {
    static let limit = 8
    private let defaults: UserDefaults
    private let key = "magpie.recentSearches"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var items: [String] { defaults.stringArray(forKey: key) ?? [] }

    func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var list = items.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}
