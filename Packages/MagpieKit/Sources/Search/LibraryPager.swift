import Foundation
import MagpieCore

/// One `search3` call: the text and, per section, how many rows and from where. New parameters (such as a library
/// folder) go here, so every call site picks them up.
public struct LibraryQuery: Equatable, Hashable, Sendable {
    public var text: String
    public var songCount: Int
    public var albumCount: Int
    public var artistCount: Int
    public var songOffset: Int
    public var albumOffset: Int
    public var artistOffset: Int

    public init(text: String, songCount: Int = 20, albumCount: Int = 10, artistCount: Int = 10,
                songOffset: Int = 0, albumOffset: Int = 0, artistOffset: Int = 0) {
        self.text = text; self.songCount = songCount; self.albumCount = albumCount; self.artistCount = artistCount
        self.songOffset = songOffset; self.albumOffset = albumOffset; self.artistOffset = artistOffset
    }
}

/// A library section that pages.
public enum LibraryKind: String, CaseIterable, Sendable, Hashable {
    case songs, albums, artists

    /// Rows per batch (plan item 3).
    public var pageSize: Int {
        switch self {
        case .songs: 20
        case .albums, .artists: 10
        }
    }
}

/// Where each query of a search's plan is up to, per section, and which rows are already shown (round 12, plan item
/// 3). Sections page on their own, so two can load at once.
public struct SearchPaging: Equatable, Sendable {
    /// One query of the plan: the whole query (`artist == nil`) or a split.
    struct Source: Equatable, Sendable {
        var text: String
        var artist: String?
    }

    struct Section: Equatable, Sendable {
        var offsets: [Int]
        var done: [Bool]
        var seen: Set<String> = []
        var loadedMore = false

        var hasMore: Bool { done.contains(false) }
    }

    /// The query as typed (for ranking new batches).
    public let query: String
    let sources: [Source]
    var sections: [LibraryKind: Section]

    public func hasMore(_ kind: LibraryKind) -> Bool { sections[kind]?.hasMore ?? false }
    /// Ids of the rows shown in a section.
    public func seen(_ kind: LibraryKind) -> Set<String> { sections[kind]?.seen ?? [] }
    /// A batch after the first has been loaded into the section.
    public func loadedMore(_ kind: LibraryKind) -> Bool { sections[kind]?.loadedMore ?? false }

    /// Marks rows as shown (rows added outside the pager, such as a song's own artist).
    mutating func insert(_ ids: some Sequence<String>, into kind: LibraryKind) {
        sections[kind]?.seen.formUnion(ids)
    }
}

/// The rows a load-more brought for one section, and that section's new paging state.
public struct MoreResults: Sendable {
    public var kind: LibraryKind
    public var songs: [Song] = []
    public var albums: [Album] = []
    public var artists: [Artist] = []
    public var paging: SearchPaging

    public init(kind: LibraryKind, songs: [Song] = [], albums: [Album] = [], artists: [Artist] = [], paging: SearchPaging) {
        self.kind = kind; self.songs = songs; self.albums = albums; self.artists = artists; self.paging = paging
    }
}

/// The library half of search: runs a query's plan (the whole query and its splits) with at most `maxConcurrent`
/// requests at a time, filters each split's rows by its artist part, drops repeats, and pages each section with
/// `search3` offsets.
///
/// Fix round 1 (review I1, I3):
/// - A query's section ends on a batch shorter than asked for, and a split's also on a batch its artist filter kept
///   nothing from (a common title word fills a batch with other artists' songs): such a split never pages.
/// - A load-more makes at most `maxRounds` rounds, and adds to "loaded more" only when rows came.
/// - On the first batch each request has its own deadline: a slow split is dropped on its own; only the whole query
///   running out of time (with nothing from the splits) is an error.
public struct LibraryPager: Sendable {
    public typealias Page = @Sendable (LibraryQuery) async throws -> LibrarySearchResult
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Five queries at most (the whole one and four splits), three at a time.
    public static let maxConcurrent = 3
    static let maxRounds = 2

    private let page: Page
    private let maxConcurrent: Int
    private let pageSize: Int?

    /// - Parameter pageSize: one batch size for every section instead of `LibraryKind.pageSize` (UI tests on the small
    ///   dev library).
    public init(maxConcurrent: Int = LibraryPager.maxConcurrent, pageSize: Int? = nil, page: @escaping Page) {
        self.page = page; self.maxConcurrent = max(1, maxConcurrent)
        self.pageSize = pageSize.map { max(1, $0) }
    }

    private func size(_ kind: LibraryKind) -> Int { pageSize ?? kind.pageSize }

    /// The first batch of every section, from the whole query and its splits. Throws only when the whole query fails
    /// (or runs out of time) and no split found anything.
    /// - Parameters:
    ///   - deadline: each request's own time limit (nil: none but the request's own).
    ///   - sleep: the clock for the deadline (tests inject one).
    ///   - onWhole: called with the whole query's rows as soon as they come, before the splits are back (fix round 2:
    ///     the first answer never waits on the splits). Not called when the whole query fails.
    public func first(_ query: String, deadline: Duration? = nil,
                      sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                      onWhole: (@Sendable (LibrarySearchResult, SearchPaging) async -> Void)? = nil)
        async throws -> (LibrarySearchResult, SearchPaging) {
        let plan = SearchPlan(query)
        let sources = [SearchPaging.Source(text: plan.whole, artist: nil)]
            + plan.splits.map { SearchPaging.Source(text: $0.title, artist: $0.artist) }
        let requests = sources.map { s in
            LibraryQuery(text: s.text, songCount: size(.songs), albumCount: size(.albums),
                         artistCount: s.artist == nil ? size(.artists) : 0)
        }
        let results = try await run(requests, deadline: deadline, sleep: sleep) { result in
            guard let onWhole, case .success = result else { return }
            let partial = [result] + Array(repeating: nil, count: sources.count - 1)
            let (found, paging, _) = assemble(query, sources, partial)
            await onWhole(found, paging)
        }
        let (found, paging, firstError) = assemble(query, sources, results)
        if let firstError, found.songs.isEmpty, found.albums.isEmpty, found.artists.isEmpty { throw firstError }
        return (found, paging)
    }

    /// The rows and paging state from the plan's results so far (nil: still out, counted as done).
    private func assemble(_ query: String, _ sources: [SearchPaging.Source],
                          _ results: [Result<LibrarySearchResult, Error>?]) -> (LibrarySearchResult, SearchPaging, Error?) {
        var paging = SearchPaging(query: query, sources: sources, sections: [:])
        for kind in LibraryKind.allCases {
            paging.sections[kind] = SearchPaging.Section(offsets: Array(repeating: 0, count: sources.count),
                                                         done: Array(repeating: false, count: sources.count))
        }
        var found = LibrarySearchResult()
        var firstError: Error?
        for (i, result) in results.enumerated() {
            switch result {
            case nil:
                for kind in LibraryKind.allCases { paging.sections[kind]?.done[i] = true }
            case .failure(let error):
                if i == 0 { firstError = error }
                for kind in LibraryKind.allCases { paging.sections[kind]?.done[i] = true }
            case .success(let rows):
                let source = sources[i]
                for kind in LibraryKind.allCases {
                    let asked = kind == .artists && source.artist != nil ? 0 : size(kind)
                    let batch = Self.filter(rows, kind, source, seen: paging.seen(kind))
                    paging.sections[kind]?.offsets[i] = batch.raw
                    paging.sections[kind]?.done[i] = asked == 0 || Self.ends(batch, asked: asked, source)
                    found.append(batch.new, kind)
                    paging.insert(batch.new.ids(kind), into: kind)
                }
            }
        }
        return (found, paging, firstError)
    }

    /// The next batch of one section, from every query of the plan that still has more: one round, and a second only
    /// when the first added nothing (never more; loads never chain on their own).
    public func more(_ kind: LibraryKind, paging: SearchPaging) async throws -> MoreResults {
        var paging = paging
        var found = LibrarySearchResult()
        for _ in 0..<Self.maxRounds {
            guard let section = paging.sections[kind], section.hasMore else { break }
            let active = section.done.indices.filter { !section.done[$0] }
            let requests = active.map { i in
                var q = LibraryQuery(text: paging.sources[i].text, songCount: 0, albumCount: 0, artistCount: 0)
                switch kind {
                case .songs: q.songCount = size(kind); q.songOffset = section.offsets[i]
                case .albums: q.albumCount = size(kind); q.albumOffset = section.offsets[i]
                case .artists: q.artistCount = size(kind); q.artistOffset = section.offsets[i]
                }
                return q
            }
            let results = try await run(requests, deadline: nil, sleep: { _ in })
            let failures = results.compactMap { if case .failure(let e) = $0 { e } else { nil } }
            // Every query failed: say so (the section can be tried again; nothing moved on).
            if failures.count == results.count, let error = failures.first { throw error }
            for (n, result) in results.enumerated() {
                let i = active[n]
                switch result {
                case .failure:
                    paging.sections[kind]?.done[i] = true   // a failing split stops; the others carry on
                case .success(let rows):
                    let batch = Self.filter(rows, kind, paging.sources[i], seen: paging.seen(kind))
                    paging.sections[kind]?.offsets[i] += batch.raw
                    paging.sections[kind]?.done[i] = Self.ends(batch, asked: size(kind), paging.sources[i])
                    found.append(batch.new, kind)
                    paging.insert(batch.new.ids(kind), into: kind)
                }
            }
            if !found.isEmpty(kind) { break }
        }
        if found.isEmpty(kind), var section = paging.sections[kind] {
            // Nothing came: the section ends here, rather than leave a footer waiting for rows that don't come.
            section.done = section.done.map { _ in true }
            paging.sections[kind] = section
        } else {
            paging.sections[kind]?.loadedMore = true
        }
        return MoreResults(kind: kind, songs: found.songs, albums: found.albums, artists: found.artists, paging: paging)
    }

    // MARK: - Running

    /// Each request's result in order, with at most `maxConcurrent` running at once, each within its own `deadline`
    /// (a late one fails with `SearchTimedOut`). Cancellation is rethrown.
    private func run(_ requests: [LibraryQuery], deadline: Duration?, sleep: @escaping Sleep,
                     onFirst: ((Result<LibrarySearchResult, Error>) async -> Void)? = nil)
        async throws -> [Result<LibrarySearchResult, Error>] {
        let page = self.page
        var results = [Result<LibrarySearchResult, Error>?](repeating: nil, count: requests.count)
        await withTaskGroup(of: (Int, Result<LibrarySearchResult, Error>).self) { group in
            var next = 0
            func add() {
                guard next < requests.count else { return }
                let i = next, q = requests[i]
                next += 1
                group.addTask {
                    // B1 (D120): the answer is awaited into a constant, then paired. An inline `.success(try await …)`
                    // in the returned pair loses `i` in the optimised build (every page landed on the first request).
                    let result: Result<LibrarySearchResult, Error>
                    do {
                        if let deadline {
                            result = .success(try await MergedSearch.withDeadline(deadline, sleep: sleep) { try await page(q) })
                        } else {
                            result = .success(try await page(q))
                        }
                    } catch {
                        result = .failure(error)
                    }
                    return (i, result)
                }
            }
            for _ in 0..<min(maxConcurrent, requests.count) { add() }
            for await (i, result) in group {
                results[i] = result
                add()
                if i == 0 { await onFirst?(result) }   // the whole query: hand it over at once
            }
        }
        try Task.checkCancellation()
        return results.map { $0 ?? .failure(CancellationError()) }
    }

    /// One section's rows from a batch: a split keeps only rows whose artist matches its artist part, and rows
    /// already shown are dropped. `raw` is how many the server sent (for the offset); `passed` how many got past the
    /// split's artist filter, repeats included.
    private static func filter(_ rows: LibrarySearchResult, _ kind: LibraryKind, _ source: SearchPaging.Source,
                               seen: Set<String>) -> (new: LibrarySearchResult, raw: Int, passed: Int) {
        var seen = seen
        var passed = 0
        func keep(_ id: String, artist: String) -> Bool {
            if let part = source.artist, !SearchRanker.nameMatches(artist, part, strict: true) { return false }
            passed += 1
            return seen.insert(id).inserted
        }
        switch kind {
        case .songs:
            let new = rows.songs.filter { keep($0.id, artist: $0.artist) }
            return (LibrarySearchResult(songs: new), rows.songs.count, passed)
        case .albums:
            let new = rows.albums.filter { keep($0.id, artist: $0.artist) }
            return (LibrarySearchResult(albums: new), rows.albums.count, passed)
        case .artists:
            guard source.artist == nil else { return (LibrarySearchResult(), 0, 0) }
            let new = rows.artists.filter { keep($0.id, artist: $0.name) }
            return (LibrarySearchResult(artists: new), rows.artists.count, passed)
        }
    }

    /// A query's section ends on a short batch; a split's also on a batch its artist filter kept nothing from.
    private static func ends(_ batch: (new: LibrarySearchResult, raw: Int, passed: Int), asked: Int,
                             _ source: SearchPaging.Source) -> Bool {
        batch.raw < asked || (source.artist != nil && batch.passed == 0)
    }
}


extension LibrarySearchResult {
    mutating func append(_ other: LibrarySearchResult, _ kind: LibraryKind) {
        switch kind {
        case .songs: songs += other.songs
        case .albums: albums += other.albums
        case .artists: artists += other.artists
        }
    }

    func ids(_ kind: LibraryKind) -> [String] {
        switch kind {
        case .songs: songs.map(\.id)
        case .albums: albums.map(\.id)
        case .artists: artists.map(\.id)
        }
    }

    func isEmpty(_ kind: LibraryKind) -> Bool { ids(kind).isEmpty }
}
