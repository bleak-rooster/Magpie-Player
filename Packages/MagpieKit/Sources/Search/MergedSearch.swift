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

    public init(songs: [ExternalRecording] = [], albums: [NotYetAlbum] = [], artists: [NotYetArtist] = []) {
        self.songs = songs; self.albums = albums; self.artists = artists
    }
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

    private let library: @Sendable (String) async throws -> LibrarySearchResult
    private let libraryTimeout: Duration
    private let sources: [Source]
    private let index: @Sendable () async -> MatchIndex
    private let sleep: Sleep

    /// - Parameters:
    ///   - index: the library's match index (a snapshot may be empty while the first one builds).
    ///   - sleep: the clock for the time limits (tests inject one).
    public init(library: @escaping @Sendable (String) async throws -> LibrarySearchResult,
                libraryTimeout: Duration = MergedSearch.libraryTimeout,
                sources: [Source],
                index: @escaping @Sendable () async -> MatchIndex,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.library = library; self.libraryTimeout = libraryTimeout; self.sources = sources
        self.index = index; self.sleep = sleep
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
        async let libraryResult: Result<LibrarySearchResult, Error> = Self.capture {
            try await Self.withDeadline(libraryTimeout, sleep: sleep) { try await library(query) }
        }
        async let outside: [ExternalHits] = withTaskGroup(of: (Int, ExternalHits).self) { group in
            for (i, source) in sources.enumerated() {
                group.addTask {
                    let hits = try? await Self.withDeadline(source.timeout, sleep: sleep) { try await source.fetch(query) }
                    return (i, hits ?? ExternalHits())
                }
            }
            var all: [(Int, ExternalHits)] = []
            for await hit in group { all.append(hit) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)    // source order, not arrival order
        }
        let lib = await libraryResult
        if let libraryFirst, case .success(let found) = lib {
            await libraryFirst(SearchSections.library(found, query: query))
        }
        let ext = await outside
        let merged = Self.merge(query: query, library: (try? lib.get()) ?? LibrarySearchResult(),
                                outside: ext, index: await index())
        if case .failure(let error) = lib, merged.notYet.isEmpty { throw error }
        return merged
    }

    // MARK: - Merging

    static func merge(query: String, library: LibrarySearchResult, outside: [ExternalHits],
                      index: MatchIndex) -> SearchSections {
        var sections = SearchSections.library(library, query: query)
        // The index may be empty or stale (first launch, mid-scan): the rows on screen count too.
        let shown = MatchIndex(songs: library.songs)
        func inLibrary(_ r: ExternalRecording) -> Bool {
            index.librarySong(for: r) != nil || shown.librarySong(for: r) != nil
        }
        func hasArtist(_ a: NotYetArtist) -> Bool {
            index.hasArtist(name: a.name, mbid: a.mbid) || shown.hasArtist(name: a.name, mbid: a.mbid)
                || library.artists.contains { ($0.mbid != nil && $0.mbid == a.mbid) || Normalize.name($0.name) == Normalize.name(a.name) }
        }
        func hasAlbum(_ a: NotYetAlbum) -> Bool {
            index.hasAlbum(title: a.title, artist: a.artist) || shown.hasAlbum(title: a.title, artist: a.artist)
                || library.albums.contains {
                    ($0.releaseGroupMBID != nil && $0.releaseGroupMBID == a.mbid)
                        || (Normalize.name($0.name) == Normalize.name(a.title) && Normalize.name($0.artist) == Normalize.name(a.artist))
                }
        }

        var notYet = NotYetSections()
        var seen = Set<String>()
        for hits in outside {
            for r in hits.songs where notYet.songs.count < limits.songs && !inLibrary(r) {
                // One row per artist + title, however many recordings share it (review H3.3).
                if seen.insert("s" + Normalize.key(artist: r.artist, title: r.title)).inserted { notYet.songs.append(r) }
            }
            for a in hits.albums where notYet.albums.count < limits.albums && !a.title.isEmpty && !hasAlbum(a) {
                let id = a.mbid?.rawValue ?? Normalize.key(artist: a.artist, title: a.title)
                if seen.insert("l" + id).inserted { notYet.albums.append(a) }
            }
            for a in hits.artists where notYet.artists.count < limits.artists && !a.name.isEmpty && !hasArtist(a) {
                if seen.insert("a" + (a.mbid?.rawValue ?? Normalize.name(a.name))).inserted { notYet.artists.append(a) }
            }
        }
        sections.notYet = notYet
        return sections
    }

    // MARK: - Time limits

    private static func capture<T>(_ op: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await op()) } catch { return .failure(error) }
    }

    /// Runs `op` until `limit` passes on `sleep`'s clock, then throws `SearchTimedOut`. The loser is
    /// cancelled and not waited for, so a source that ignores cancellation can't hold search up.
    static func withDeadline<T: Sendable>(_ limit: Duration, sleep: @escaping Sleep,
                                          _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                race.start(c, tasks: [
                    Task { race.finish(await capture(op)) },
                    Task {
                        do {
                            try await sleep(limit)
                            race.finish(.failure(SearchTimedOut()))
                        } catch {}   // cancelled: the work won
                    },
                ])
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

/// First result wins; both tasks are then cancelled.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func start(_ c: CheckedContinuation<T, Error>, tasks new: [Task<Void, Never>]) {
        lock.lock()
        if let result {
            lock.unlock()
            new.forEach { $0.cancel() }
            c.resume(with: result)
            return
        }
        continuation = c
        tasks = new
        lock.unlock()
    }

    func finish(_ r: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let c = continuation, ts = tasks
        continuation = nil
        tasks = []
        lock.unlock()
        ts.forEach { $0.cancel() }
        c?.resume(with: r)
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
