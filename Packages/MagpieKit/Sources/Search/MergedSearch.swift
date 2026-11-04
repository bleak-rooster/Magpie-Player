import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
import MatchIndex

/// What one outside source found for a query.
public struct ExternalHits: Equatable, Sendable {
    public var songs: [ExternalRecording]
    public var albums: [NotYetAlbum]
    public var artists: [NotYetArtist]
    /// Round 14 (D98): where the source is up to, for Load more.
    public var cursor: OutsideCursor

    public init(songs: [ExternalRecording] = [], albums: [NotYetAlbum] = [], artists: [NotYetArtist] = [],
                cursor: OutsideCursor = OutsideCursor()) {
        self.songs = songs; self.albums = albums; self.artists = artists; self.cursor = cursor
    }

    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty && cursor == OutsideCursor() }
}

public struct SearchTimedOut: Error, Equatable {}

/// Library search merged with songs, albums and artists from outside it. The library (3 s) and each
/// source (ListenBrainz 5 s, Lidarr 5 s when connected) run in parallel; a source that fails or runs
/// out of time adds nothing. Outside hits the library already has (match ladder) are dropped, since
/// they are shown as library rows. Library results come first and the top result is always from the
/// library (D4); the rest go in the "Not in your library" band.
public struct MergedSearch: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public struct Source: Sendable {
        public var timeout: Duration
        public var fetch: @Sendable (String) async throws -> ExternalHits

        public init(timeout: Duration, fetch: @escaping @Sendable (String) async throws -> ExternalHits) {
            self.timeout = timeout; self.fetch = fetch
        }
    }

    public static let libraryTimeout: Duration = .seconds(3)
    public static let sourceTimeout: Duration = .seconds(5)
    /// Most rows per kind in the "Not in your library" band.
    public static let limits = (songs: 10, albums: 8, artists: 5)

    private let library: @Sendable (String) async throws -> (LibrarySearchResult, SearchPaging?)
    private let pager: LibraryPager?
    private let libraryTimeout: Duration
    private let sources: [Source]
    let outsideMore: OutsideMore
    let index: @Sendable () async -> MatchIndex
    let sleep: Sleep

    /// A library searched by text alone, one batch, no split queries and no paging (tests).
    /// - Parameters:
    ///   - index: the library's match index (a snapshot may be empty while the first one builds).
    ///   - sleep: the clock for the time limits (tests inject one).
    public init(library: @escaping @Sendable (String) async throws -> LibrarySearchResult,
                libraryTimeout: Duration = MergedSearch.libraryTimeout,
                sources: [Source],
                outsideMore: OutsideMore = OutsideMore(),
                index: @escaping @Sendable () async -> MatchIndex,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.library = { (try await library($0), nil) }
        self.pager = nil
        self.libraryTimeout = libraryTimeout; self.sources = sources; self.outsideMore = outsideMore
        self.index = index; self.sleep = sleep
    }

    /// The library through `search3` with counts and offsets (round 12): the whole query plus its split queries
    /// (`SearchPlan`), and sections that page (`more`). `pageSize` overrides the batch sizes (UI tests).
    public init(libraryPage: @escaping LibraryPager.Page,
                pageSize: Int? = nil,
                libraryTimeout: Duration = MergedSearch.libraryTimeout,
                sources: [Source],
                outsideMore: OutsideMore = OutsideMore(),
                index: @escaping @Sendable () async -> MatchIndex,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        let pager = LibraryPager(pageSize: pageSize, page: libraryPage)
        // Fix round 1 (I3): the whole query and each split get their own deadline, so a slow split is dropped on its
        // own and never hides the whole query's rows.
        self.library = { q in
            let (found, paging) = try await pager.first(q, deadline: libraryTimeout, sleep: sleep)
            return (found, paging)
        }
        self.pager = pager
        self.libraryTimeout = libraryTimeout; self.sources = sources; self.outsideMore = outsideMore
        self.index = index; self.sleep = sleep
    }

    /// The next batch of one library section (plan item 3), for `SearchSections.append`. Cancellation is rethrown.
    public func more(_ kind: LibraryKind, paging: SearchPaging) async throws -> MoreResults {
        guard let pager else { return MoreResults(kind: kind, paging: paging) }
        return try await pager.more(kind, paging: paging)
    }

    public func run(_ q: String) async -> SearchSections {
        (try? await runReportingLibraryFailure(q)) ?? .empty
    }

    /// Like `run`, but when the library search fails (or runs out of time) and nothing came from
    /// outside either, throws the library's error so the screen can say search didn't work.
    ///
    /// - Parameter libraryFirst: called with the library-only sections as soon as the library answers,
    ///   so library rows never wait for slower outside sources. The return value adds the band.
    public func runReportingLibraryFailure(
        _ q: String, libraryFirst: (@Sendable (SearchSections) async -> Void)? = nil
    ) async throws -> SearchSections {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .empty }
        let library = self.library, sleep = self.sleep, libraryTimeout = self.libraryTimeout, sources = self.sources
        let pager = self.pager
        // Fix round 2: the whole query's rows go to `libraryFirst` the moment they come; the splits follow.
        var onWhole: (@Sendable (LibrarySearchResult, SearchPaging) async -> Void)?
        if let libraryFirst {
            onWhole = { @Sendable found, paging in
                await libraryFirst(Self.librarySections(found, paging: paging, query: query))
            }
        }
        let whole = onWhole
        async let libraryResult: Result<(LibrarySearchResult, SearchPaging?), Error> = Self.capture {
            if let pager {   // the paged library times each request itself (fix round 1, I3)
                let (found, paging) = try await pager.first(query, deadline: libraryTimeout, sleep: sleep, onWhole: whole)
                return (found, paging)
            }
            return try await Self.withDeadline(libraryTimeout, sleep: sleep) { try await library(query) }
        }
        // Round 14 (D97): each source on its own; the band grows as each one answers (after the library), so a slow
        // source never holds back another's rows.
        let (arrivals, arrived) = AsyncStream.makeStream(of: (Int, ExternalHits).self)
        async let outsideDone: Void = withTaskGroup(of: Void.self) { group in
            for (i, source) in sources.enumerated() {
                group.addTask {
                    let hits = try? await Self.withDeadline(source.timeout, sleep: sleep) { try await source.fetch(query) }
                    arrived.yield((i, hits ?? ExternalHits()))
                }
            }
            await group.waitForAll()
            arrived.finish()
        }
        let lib = await libraryResult
        // Every library row (the splits' too) still never waits for the outside sources.
        if let libraryFirst, case .success(let (found, paging)) = lib {
            await libraryFirst(Self.librarySections(found, paging: paging, query: query))
        }
        let (found, paging) = (try? lib.get()) ?? (LibrarySearchResult(), nil)
        var got: [Int: ExternalHits] = [:]
        for await (i, hits) in arrivals {
            got[i] = hits
            if let libraryFirst, case .success = lib, got.count < sources.count, !hits.isEmpty {
                let soFar = got.sorted { $0.key < $1.key }.map(\.value)   // source order, not arrival order
                await libraryFirst(Self.merge(query: query, library: found, paging: paging, outside: soFar,
                                              index: await index()))
            }
        }
        await outsideDone
        let ext = got.sorted { $0.key < $1.key }.map(\.value)
        let merged = Self.merge(query: query, library: found, paging: paging, outside: ext, index: await index())
        if case .failure(let error) = lib, merged.notYet.isEmpty { throw error }
        return merged
    }

    // MARK: - Merging

    /// The library's sections, ranked, with the best song's artist and album (plan item 1.3) and the paging state
    /// (which counts those rows as shown).
    static func librarySections(_ library: LibrarySearchResult, paging: SearchPaging?, query: String) -> SearchSections {
        var sections = SearchSections.library(library, query: query, withSongsArtist: true)
        if var paging {
            paging.insert(sections.artists.map(\.id), into: .artists)
            paging.insert(sections.albums.map(\.id), into: .albums)
            sections.paging = paging
        }
        return sections
    }

    static func merge(query: String, library: LibrarySearchResult, paging: SearchPaging? = nil, outside: [ExternalHits],
                      index: MatchIndex) -> SearchSections {
        var sections = librarySections(library, paging: paging, query: query)
        // The index may be empty or stale (first launch, mid-scan): the rows on screen count too.
        let check = LibraryCheck(index: index, library: library)

        // Every candidate, in source order, without repeats; then ranked (round 12: the same scorer as the library;
        // equal scores keep source order). The first page shows; the rest wait for Load more (round 14, D98).
        var all = NotYetSections()
        var seen = Set<String>()
        var ownedIds = Set<String>()
        var cursor = OutsideCursor()
        for hits in outside {
            for r in hits.songs {
                switch check.song(r) {
                case .drop: continue
                case .owned(let id):
                    if ownedIds.insert(id).inserted { all.owned.append(OwnedOutsideSong(recording: r, songId: id)) }
                case .outside:
                    // One row per artist + title (review H3.3) and per recording MBID (round 14), whichever source.
                    let keys = LibraryCheck.songKeys(r)
                    if keys.allSatisfy({ !seen.contains($0) }) { seen.formUnion(keys); all.songs.append(r) }
                }
            }
            for a in hits.albums where !a.title.isEmpty && !check.hasAlbum(a) {
                if seen.insert(LibraryCheck.albumKey(a)).inserted { all.albums.append(a) }
            }
            for a in hits.artists where !a.name.isEmpty && !check.hasArtist(a) {
                if seen.insert(LibraryCheck.artistKey(a)).inserted { all.artists.append(a) }
            }
            cursor.absorb(hits.cursor)
        }
        let q = SearchRanker.Query(query)
        all.songs = SearchRanker.rank(all.songs, q, SearchRanker.score(recording:_:))
        all.albums = SearchRanker.rank(all.albums, q, SearchRanker.score(notYetAlbum:_:))
        all.artists = SearchRanker.rank(all.artists, q, SearchRanker.score(notYetArtist:_:))
        var notYet = NotYetSections(owned: all.owned)
        var queued = NotYetSections()
        notYet.songs = take(&all.songs, limits.songs); queued.songs = all.songs
        notYet.albums = take(&all.albums, limits.albums); queued.albums = all.albums
        notYet.artists = take(&all.artists, limits.artists); queued.artists = all.artists
        sections.notYet = notYet
        sections.outside = OutsidePaging(query: query, queued: queued, cursor: cursor)
        return sections
    }

    // MARK: - Time limits

    static func capture<T>(_ op: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await op()) } catch { return .failure(error) }
    }

    /// Runs `op` until `limit` passes on `sleep`'s clock, then throws `SearchTimedOut`. The loser is
    /// cancelled and not waited for, so a source that ignores cancellation can't hold search up. B1 fix round: one
    /// shared helper (`Deadline.run`).
    static func withDeadline<T: Sendable>(_ limit: Duration, sleep: @escaping Sleep,
                                          _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        switch await Deadline.run(limit, sleep: sleep, op) {
        case .success(let value): return value
        case .failure(let error) where error is Deadline.Exceeded: throw SearchTimedOut()
        case .failure(let error): throw error
        }
    }
}

// MARK: - Sources

extension MergedSearch.Source {
    /// ListenBrainz labs recording search (no credentials, A9): songs.
    public static func listenBrainz(_ client: ListenBrainzClient,
                                    timeout: Duration = MergedSearch.sourceTimeout) -> Self {
        Self(timeout: timeout) { q in ExternalHits(songs: try await client.searchRecordings(q)) }
    }

    /// Lidarr text search (A10: artist and album rows only). Read-only.
    public static func lidarr(_ client: LidarrClient, timeout: Duration = MergedSearch.sourceTimeout) -> Self {
        Self(timeout: timeout) { q in Self.hits(from: try await client.search(term: q)) }
    }

    static func hits(from rows: [LidarrSearchHit]) -> ExternalHits {
        var hits = ExternalHits()
        let calendar = Calendar(identifier: .gregorian)
        for row in rows {
            switch row.kind {
            case .artist:
                hits.artists.append(NotYetArtist(name: row.artistName, mbid: row.artistMBID ?? row.foreignId))
            case .album:
                hits.albums.append(NotYetAlbum(title: row.albumTitle ?? "", artist: row.artistName, mbid: row.foreignId,
                                               artistMBID: row.artistMBID,
                                               year: row.releaseDate.map { calendar.component(.year, from: $0) },
                                               kind: row.albumType))
            }
        }
        return hits
    }
}
