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
/// `search3` offsets. A batch shorter than asked for ends that query's section; a load-more keeps going (up to
/// `maxRounds` batches) while a split's filter drops everything, so the screen never waits on an empty batch.
public struct LibraryPager: Sendable {
    public typealias Page = @Sendable (LibraryQuery) async throws -> LibrarySearchResult

    /// Five queries at most (the whole one and four splits), three at a time.
    public static let maxConcurrent = 3
    static let maxRounds = 5

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
    /// and no split found anything.
    public func first(_ query: String) async throws -> (LibrarySearchResult, SearchPaging) {
        let plan = SearchPlan(query)
        let sources = [SearchPaging.Source(text: plan.whole, artist: nil)]
            + plan.splits.map { SearchPaging.Source(text: $0.title, artist: $0.artist) }
        let requests = sources.map { s in
            LibraryQuery(text: s.text, songCount: size(.songs), albumCount: size(.albums),
                         artistCount: s.artist == nil ? size(.artists) : 0)
        }
        let results = try await run(requests)
        var paging = SearchPaging(query: query, sources: sources, sections: [:])
        for kind in LibraryKind.allCases {
            paging.sections[kind] = SearchPaging.Section(offsets: Array(repeating: 0, count: sources.count),
                                                         done: Array(repeating: false, count: sources.count))
        }
        var found = LibrarySearchResult()
        var firstError: Error?
        for (i, result) in results.enumerated() {
            switch result {
            case .failure(let error):
                if i == 0 { firstError = error }
                for kind in LibraryKind.allCases { paging.sections[kind]?.done[i] = true }
            case .success(let rows):
                let source = sources[i]
                for kind in LibraryKind.allCases {
                    let asked = kind == .artists && source.artist != nil ? 0 : size(kind)
                    let (new, raw) = Self.filter(rows, kind, source, seen: paging.seen(kind))
                    paging.sections[kind]?.offsets[i] = raw
                    paging.sections[kind]?.done[i] = asked == 0 || raw < asked
                    found.append(new, kind)
                    paging.insert(new.ids(kind), into: kind)
                }
            }
        }
        if let firstError, found.songs.isEmpty, found.albums.isEmpty, found.artists.isEmpty { throw firstError }
        return (found, paging)
    }

    /// The next batch of one section, from every query of the plan that still has more.
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
            let results = try await run(requests)
            let failures = results.compactMap { if case .failure(let e) = $0 { e } else { nil } }
            // Every query failed: say so (the section can be tried again; nothing moved on).
            if failures.count == results.count, let error = failures.first { throw error }
            for (n, result) in results.enumerated() {
                let i = active[n]
                switch result {
                case .failure:
                    paging.sections[kind]?.done[i] = true   // a failing split stops; the others carry on
                case .success(let rows):
                    let (new, raw) = Self.filter(rows, kind, paging.sources[i], seen: paging.seen(kind))
                    paging.sections[kind]?.offsets[i] += raw
                    paging.sections[kind]?.done[i] = raw < size(kind)
                    found.append(new, kind)
                    paging.insert(new.ids(kind), into: kind)
                }
            }
            if !found.isEmpty(kind) { break }
        }
        // Still nothing after the last round: stop, rather than leave a footer waiting for rows that don't come.
        if found.isEmpty(kind), var section = paging.sections[kind] {
            section.done = section.done.map { _ in true }
            paging.sections[kind] = section
        }
        paging.sections[kind]?.loadedMore = true
        return MoreResults(kind: kind, songs: found.songs, albums: found.albums, artists: found.artists, paging: paging)
    }

    // MARK: - Running

    /// Each request's result in order, with at most `maxConcurrent` running at once. Cancellation is rethrown.
    private func run(_ requests: [LibraryQuery]) async throws -> [Result<LibrarySearchResult, Error>] {
        let page = self.page
        var results = [Result<LibrarySearchResult, Error>?](repeating: nil, count: requests.count)
        await withTaskGroup(of: (Int, Result<LibrarySearchResult, Error>).self) { group in
            var next = 0
            func add() {
                guard next < requests.count else { return }
                let i = next, q = requests[i]
                next += 1
                group.addTask {
                    do { return (i, .success(try await page(q))) } catch { return (i, .failure(error)) }
                }
            }
            for _ in 0..<min(maxConcurrent, requests.count) { add() }
            for await (i, result) in group {
                results[i] = result
                add()
            }
        }
        try Task.checkCancellation()
        return results.map { $0 ?? .failure(CancellationError()) }
    }

    /// One section's rows from a batch: a split keeps only rows whose artist matches its artist part, and rows
    /// already shown are dropped. `raw` is how many the server sent (for the offset).
    private static func filter(_ rows: LibrarySearchResult, _ kind: LibraryKind, _ source: SearchPaging.Source,
                               seen: Set<String>) -> (LibrarySearchResult, raw: Int) {
        var seen = seen
        func keep(_ id: String, artist: String) -> Bool {
            if let part = source.artist, !SearchRanker.nameMatches(artist, part) { return false }
            return seen.insert(id).inserted
        }
        switch kind {
        case .songs:
            return (LibrarySearchResult(songs: rows.songs.filter { keep($0.id, artist: $0.artist) }), rows.songs.count)
        case .albums:
            return (LibrarySearchResult(albums: rows.albums.filter { keep($0.id, artist: $0.artist) }), rows.albums.count)
        case .artists:
            guard source.artist == nil else { return (LibrarySearchResult(), 0) }
            return (LibrarySearchResult(artists: rows.artists.filter { keep($0.id, artist: $0.name) }), rows.artists.count)
        }
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
