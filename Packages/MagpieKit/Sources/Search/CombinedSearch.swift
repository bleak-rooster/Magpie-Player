import AurralKit
import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
import MatchIndex

// Round 14 A5 (owner answer 5, D95–D99): combined search.
// - Songs: the library's first; then the songs on the albums Lidarr's search returns for the term (their tracklists
//   from MusicBrainz, which Lidarr itself uses), keeping those whose title matches the term or the term without the
//   album's artist. ListenBrainz song search only when Lidarr has no album hit. One row per recording MBID.
// - Artists and albums: Aurral's paged search merged with Lidarr's, one row per MBID. Each source on its own deadline;
//   one failing or slow never holds the other's rows back.
// - The band pages too: rows past the first page wait in memory, then Aurral's next offset or the next albums'
//   tracklists.

/// A kind of row in the "Not in your library" band.
public enum OutsideKind: String, CaseIterable, Sendable {
    case songs, artists, albums
}

/// A song found outside (an album's tracklist) that the library already has (D96): matched by recording MBID or ISRC,
/// else artist + title + duration; never by name alone. Shown "In your library" and played from the library.
public struct OwnedOutsideSong: Hashable, Sendable {
    public var recording: ExternalRecording
    /// The library song's id.
    public var songId: String

    public init(recording: ExternalRecording, songId: String) { self.recording = recording; self.songId = songId }
}

/// Where each outside source is up to, for Load more.
public struct OutsideCursor: Equatable, Sendable {
    /// Albums whose tracklists haven't been read yet (songs).
    public var unreadAlbums: [NotYetAlbum]
    /// Aurral's next offset for artists and albums (nil: no more).
    public var aurralArtistsOffset: Int?
    public var aurralAlbumsOffset: Int?

    public init(unreadAlbums: [NotYetAlbum] = [], aurralArtistsOffset: Int? = nil, aurralAlbumsOffset: Int? = nil) {
        self.unreadAlbums = unreadAlbums
        self.aurralArtistsOffset = aurralArtistsOffset; self.aurralAlbumsOffset = aurralAlbumsOffset
    }

    mutating func absorb(_ other: OutsideCursor) {
        let known = Set(unreadAlbums.compactMap(\.mbid))
        unreadAlbums += other.unreadAlbums.filter { $0.mbid.map { !known.contains($0) } ?? true }
        aurralArtistsOffset = aurralArtistsOffset ?? other.aurralArtistsOffset
        aurralAlbumsOffset = aurralAlbumsOffset ?? other.aurralAlbumsOffset
    }
}

/// The band's paging: rows already found but past the first page (`queued`), and each source's cursor.
public struct OutsidePaging: Equatable, Sendable {
    public var query: String
    public var queued: NotYetSections
    public var cursor: OutsideCursor

    public init(query: String, queued: NotYetSections = NotYetSections(), cursor: OutsideCursor = OutsideCursor()) {
        self.query = query; self.queued = queued; self.cursor = cursor
    }

    public func hasMore(_ kind: OutsideKind) -> Bool {
        switch kind {
        case .songs: !queued.songs.isEmpty || !cursor.unreadAlbums.isEmpty
        case .artists: !queued.artists.isEmpty || cursor.aurralArtistsOffset != nil
        case .albums: !queued.albums.isEmpty || cursor.aurralAlbumsOffset != nil
        }
    }

    /// Takes one kind's queue and cursor from `other`, leaving the other kinds' as they are (a load-more of one kind
    /// never undoes another's).
    mutating func take(_ kind: OutsideKind, from other: OutsidePaging) {
        switch kind {
        case .songs:
            queued.songs = other.queued.songs
            cursor.unreadAlbums = other.cursor.unreadAlbums
        case .artists:
            queued.artists = other.queued.artists
            cursor.aurralArtistsOffset = other.cursor.aurralArtistsOffset
        case .albums:
            queued.albums = other.queued.albums
            cursor.aurralAlbumsOffset = other.cursor.aurralAlbumsOffset
        }
    }
}

/// One Load more of the band: the new rows of one kind, and that kind's paging after it.
public struct OutsideMoreResults: Equatable, Sendable {
    public var kind: OutsideKind
    public var songs: [ExternalRecording]
    public var owned: [OwnedOutsideSong]
    public var artists: [NotYetArtist]
    public var albums: [NotYetAlbum]
    public var paging: OutsidePaging

    public init(kind: OutsideKind, songs: [ExternalRecording] = [], owned: [OwnedOutsideSong] = [],
                artists: [NotYetArtist] = [], albums: [NotYetAlbum] = [], paging: OutsidePaging) {
        self.kind = kind; self.songs = songs; self.owned = owned; self.artists = artists; self.albums = albums
        self.paging = paging
    }
}

// MARK: - Tracklist songs

/// Songs from albums' tracklists (D95): an album's release (OutsideCatalog's pick, through the one rate-limited
/// MusicBrainz client) and the tracks whose title matches the query.
public struct TracklistSongs: Sendable {
    public typealias Release = @Sendable (MBID) async throws -> MBReleaseDetail?

    /// Albums read per search or Load more (MusicBrainz allows one request a second).
    public static let albumsPerRead = 3
    /// Most albums considered for one query.
    public static let maxAlbums = 12
    /// How long one read may take before it keeps what came.
    public static let budget: Duration = .seconds(4)

    private let release: Release
    private let budget: Duration
    private let sleep: MergedSearch.Sleep

    public init(release: @escaping Release, budget: Duration = TracklistSongs.budget,
                sleep: @escaping MergedSearch.Sleep = { try await Task.sleep(for: $0) }) {
        self.release = release; self.budget = budget; self.sleep = sleep
    }

    /// The albums worth reading for `query`: those with a release group MBID, once each, best match first, capped.
    public static func candidates(_ albums: [NotYetAlbum], query: String) -> [NotYetAlbum] {
        var seen = Set<MBID>()
        let withIds = albums.filter { a in a.mbid.map { seen.insert($0).inserted } ?? false }
        return Array(SearchRanker.rank(withIds, SearchRanker.Query(query), SearchRanker.score(notYetAlbum:_:)).prefix(maxAlbums))
    }

    /// Whether a track's title matches: its normalised title holds the normalised query (or the query without the
    /// album's artist) as whole words. The artist alone matches nothing (it would match every song).
    public static func matches(title: String, query: String, artist: String) -> Bool {
        let t = " " + Normalize.name(title) + " "
        let q = Normalize.name(query)
        guard !q.isEmpty, t.count > 2 else { return false }
        var terms = [q]
        let a = Normalize.name(artist)
        for name in [a, a.hasPrefix("the ") ? String(a.dropFirst(4)) : ""] where !name.isEmpty {
            let padded = " " + q + " "
            if padded.contains(" " + name + " ") {
                let rest = padded.replacingOccurrences(of: " " + name + " ", with: " ")
                    .split(separator: " ").joined(separator: " ")
                terms.append(rest)
            }
        }
        return terms.contains { term in
            !term.isEmpty && term != a && t.contains(" " + term + " ")
        }
    }

    /// Reads up to `albumsPerRead` albums in order, within the budget. Returns the matching songs and the albums not
    /// read (an album cut off by the budget is read again next time). An album that fails is skipped.
    public func read(query: String, albums: [NotYetAlbum]) async -> (songs: [ExternalRecording], unread: [NotYetAlbum]) {
        let batch = Array(albums.prefix(Self.albumsPerRead))
        guard !batch.isEmpty else { return ([], albums) }
        let box = ReadBox()
        let release = self.release
        _ = try? await MergedSearch.withDeadline(budget, sleep: sleep) {
            for album in batch {
                try Task.checkCancellation()
                var songs: [ExternalRecording] = []
                if let id = album.mbid, let picked = try? await release(id) {
                    songs = OutsideReleasePick.recordings(picked, artist: album.artist, artistMBID: album.artistMBID)
                        .filter { Self.matches(title: $0.title, query: query, artist: album.artist) }
                }
                try Task.checkCancellation()
                box.finish(songs)
            }
        }
        let (songs, done) = box.snapshot
        return (songs, Array(albums.dropFirst(done)))
    }
}

private final class ReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var songs: [ExternalRecording] = []
    private var done = 0
    func finish(_ found: [ExternalRecording]) { lock.withLock { songs += found; done += 1 } }
    var snapshot: ([ExternalRecording], Int) { lock.withLock { (songs, done) } }
}

// MARK: - One Lidarr search for two sources

/// Lidarr's search for a query, asked once and shared by the artist/album source and the songs source (which reads
/// the albums' tracklists). It runs on its own deadline.
public actor SharedOutsideSearch {
    public typealias Search = @Sendable (String) async throws -> ExternalHits

    private let search: Search
    private let timeout: Duration
    private let sleep: MergedSearch.Sleep
    private var running: [String: Task<ExternalHits, Error>] = [:]

    public init(timeout: Duration = MergedSearch.sourceTimeout,
                sleep: @escaping MergedSearch.Sleep = { try await Task.sleep(for: $0) },
                search: @escaping Search) {
        self.search = search; self.timeout = timeout; self.sleep = sleep
    }

    /// Lidarr's text search (A10: artists and albums only). Read-only.
    public init(lidarr: LidarrClient, timeout: Duration = MergedSearch.sourceTimeout) {
        self.init(timeout: timeout) { q in MergedSearch.Source.hits(from: try await lidarr.search(term: q)) }
    }

    public func hits(_ query: String) async throws -> ExternalHits {
        if let task = running[query] { return try await task.value }
        let search = self.search, timeout = self.timeout, sleep = self.sleep
        let task = Task { try await MergedSearch.withDeadline(timeout, sleep: sleep) { try await search(query) } }
        running[query] = task
        return try await task.value
    }
}

// MARK: - Sources

extension MergedSearch {
    /// A song search by text (ListenBrainz's, the backup).
    public typealias SongSearch = @Sendable (String) async throws -> [ExternalRecording]

    /// The songs source's deadline: Lidarr's search, then a tracklist read (or the backup).
    public static let songsTimeout: Duration = .seconds(10)

    /// What Load more asks the outside sources for, past the first page.
    public struct OutsideMore: Sendable {
        public typealias Page<T> = @Sendable (_ query: String, _ offset: Int) async throws -> (items: [T], next: Int?)

        public var artists: Page<NotYetArtist>?
        public var albums: Page<NotYetAlbum>?
        public var tracklists: TracklistSongs?
        public var timeout: Duration

        public init(artists: Page<NotYetArtist>? = nil, albums: Page<NotYetAlbum>? = nil, tracklists: TracklistSongs? = nil,
                    timeout: Duration = MergedSearch.sourceTimeout) {
            self.artists = artists; self.albums = albums; self.tracklists = tracklists; self.timeout = timeout
        }

        /// Aurral's next pages of artists and albums.
        public static func aurral(_ client: AurralClient, pageSize: Int = Source.aurralPageSize,
                                  tracklists: TracklistSongs? = nil) -> OutsideMore {
            OutsideMore(artists: { q, offset in
                            let page = try await client.searchArtists(q, limit: pageSize, offset: offset)
                            return (page.items.map(Source.notYet), page.hasMore ? offset + page.items.count : nil)
                        },
                        albums: { q, offset in
                            let page = try await client.searchAlbums(q, limit: pageSize, offset: offset)
                            return (page.items.map(Source.notYet), page.hasMore ? offset + page.items.count : nil)
                        },
                        tracklists: tracklists)
        }
    }
}

extension MergedSearch.Source {
    public static let aurralPageSize = 24

    /// Lidarr's artists and albums, from the shared search.
    public static func lidarr(_ shared: SharedOutsideSearch, timeout: Duration = MergedSearch.sourceTimeout) -> Self {
        Self(timeout: timeout) { q in
            let hits = try await shared.hits(q)
            return ExternalHits(albums: hits.albums, artists: hits.artists)
        }
    }

    /// Songs from the tracklists of the albums Lidarr's search returns; the backup (ListenBrainz) only when Lidarr has
    /// no album hit (none, or Lidarr failed). No backup: no songs then.
    public static func songs(lidarr shared: SharedOutsideSearch, tracklists: TracklistSongs,
                             backup: MergedSearch.SongSearch?, timeout: Duration = MergedSearch.songsTimeout) -> Self {
        Self(timeout: timeout) { q in
            let albums = TracklistSongs.candidates((try? await shared.hits(q))?.albums ?? [], query: q)
            if albums.isEmpty {
                guard let backup else { return ExternalHits() }
                return ExternalHits(songs: try await backup(q))
            }
            let read = await tracklists.read(query: q, albums: albums)
            return ExternalHits(songs: read.songs, cursor: OutsideCursor(unreadAlbums: read.unread))
        }
    }

    /// Aurral's catalog search (2.13, `search` capability): a page of artists and a page of albums, side by side, each
    /// with its next offset. One failing still gives the other; both failing fails the source.
    public static func aurral(_ client: AurralClient, pageSize: Int = aurralPageSize,
                              timeout: Duration = MergedSearch.sourceTimeout) -> Self {
        Self(timeout: timeout) { q in
            async let a = MergedSearch.capture { try await client.searchArtists(q, limit: pageSize, offset: 0) }
            async let b = MergedSearch.capture { try await client.searchAlbums(q, limit: pageSize, offset: 0) }
            let (artists, albums) = await (a, b)
            if case .failure(let error) = artists, case .failure = albums { throw error }
            var hits = ExternalHits()
            if case .success(let page) = artists {
                hits.artists = page.items.map(notYet)
                hits.cursor.aurralArtistsOffset = page.hasMore ? page.items.count : nil
            }
            if case .success(let page) = albums {
                hits.albums = page.items.map(notYet)
                hits.cursor.aurralAlbumsOffset = page.hasMore ? page.items.count : nil
            }
            return hits
        }
    }

    static func notYet(_ a: AurralSearchArtist) -> NotYetArtist { NotYetArtist(name: a.name, mbid: a.mbid) }

    static func notYet(_ a: AurralSearchAlbum) -> NotYetAlbum {
        NotYetAlbum(title: a.title, artist: a.artistName, mbid: a.mbid, artistMBID: a.artistMBID,
                    year: a.releaseDate.flatMap { Int($0.prefix(4)) }, kind: a.secondaryTypes.first ?? a.primaryType)
    }
}

// MARK: - Which outside rows the library already has

/// Sorts outside rows against the library: the match index (the whole library) and the rows on screen.
struct LibraryCheck {
    let index: MatchIndex
    let library: LibrarySearchResult
    let shown: MatchIndex
    let shownIds: Set<String>

    init(index: MatchIndex, library: LibrarySearchResult) {
        self.index = index; self.library = library
        shown = MatchIndex(songs: library.songs)
        shownIds = Set(library.songs.map(\.id))
    }

    enum Verdict { case outside, drop, owned(String) }

    /// A tracklist song (it carries a recording MBID and a length) is the library's only by MBID, ISRC or artist + title
    /// + duration (D96). A ListenBrainz song keeps the old rule (labs search has no durations): any library match drops it.
    func song(_ r: ExternalRecording) -> Verdict {
        if r.source == .listenBrainz {
            return index.librarySong(for: r) != nil || shown.librarySong(for: r) != nil ? .drop : .outside
        }
        if let m = shown.match(r), m.confidence >= MatchIndex.acceptThreshold { return .drop }
        if let m = index.match(r), m.confidence >= MatchIndex.acceptThreshold {
            return shownIds.contains(m.songId) ? .drop : .owned(m.songId)
        }
        return .outside
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

    /// Keys that make two outside rows the same row.
    static func songKeys(_ r: ExternalRecording) -> [String] {
        ["s" + Normalize.key(artist: r.artist, title: r.title)] + (r.recordingMBID.map { ["m" + $0.rawValue] } ?? [])
    }

    static func albumKey(_ a: NotYetAlbum) -> String { "l" + (a.mbid?.rawValue ?? Normalize.key(artist: a.artist, title: a.title)) }
    static func artistKey(_ a: NotYetArtist) -> String { "a" + (a.mbid?.rawValue ?? Normalize.name(a.name)) }
}

// MARK: - Load more

extension MergedSearch {
    /// The next page of one kind of outside row: what's queued first, then the source's next page (Aurral's offset, or
    /// the next albums' tracklists). Throws when Aurral's page fails (the footer offers to try again); nothing moves.
    public func moreOutside(_ kind: OutsideKind, in sections: SearchSections) async throws -> OutsideMoreResults {
        guard var paging = sections.outside else {
            return OutsideMoreResults(kind: kind, paging: OutsidePaging(query: ""))
        }
        let query = paging.query
        let q = SearchRanker.Query(query)
        let check = LibraryCheck(index: await index(),
                                 library: LibrarySearchResult(songs: sections.songs, albums: sections.albums,
                                                              artists: sections.artists))
        let band = sections.notYet
        var result = OutsideMoreResults(kind: kind, paging: paging)
        switch kind {
        case .songs:
            let limit = Self.limits.songs
            var rows = Self.take(&paging.queued.songs, limit)
            var seen = Set((band.songs + rows + paging.queued.songs).flatMap(LibraryCheck.songKeys))
            var ownedIds = Set(band.owned.map(\.songId))
            while rows.count < limit, !paging.cursor.unreadAlbums.isEmpty, let reader = outsideMore.tracklists {
                let before = paging.cursor.unreadAlbums.count
                let read = await reader.read(query: query, albums: paging.cursor.unreadAlbums)
                try Task.checkCancellation()
                paging.cursor.unreadAlbums = read.unread
                var fresh: [ExternalRecording] = []
                for r in read.songs {
                    switch check.song(r) {
                    case .drop: continue
                    case .owned(let id): if ownedIds.insert(id).inserted { result.owned.append(OwnedOutsideSong(recording: r, songId: id)) }
                    case .outside:
                        let keys = LibraryCheck.songKeys(r)
                        if keys.allSatisfy({ !seen.contains($0) }) { seen.formUnion(keys); fresh.append(r) }
                    }
                }
                fresh = SearchRanker.rank(fresh, q, SearchRanker.score(recording:_:))
                let room = limit - rows.count
                rows += fresh.prefix(room)
                paging.queued.songs += fresh.dropFirst(room)
                // One read per tap once something came; none read (MusicBrainz slow or down): the footer stays.
                if read.unread.count >= before || !rows.isEmpty || !result.owned.isEmpty { break }
            }
            if outsideMore.tracklists == nil { paging.cursor.unreadAlbums = [] }
            result.songs = rows
        case .artists:
            let limit = Self.limits.artists
            var rows = Self.take(&paging.queued.artists, limit)
            if rows.count < limit, let offset = paging.cursor.aurralArtistsOffset {
                if let fetch = outsideMore.artists {
                    let page = try await Self.withDeadline(outsideMore.timeout, sleep: sleep) { try await fetch(query, offset) }
                    paging.cursor.aurralArtistsOffset = page.next
                    var seen = Set((band.artists + rows + paging.queued.artists).map(LibraryCheck.artistKey))
                    let fresh = SearchRanker.rank(page.items.filter {
                        !$0.name.isEmpty && !check.hasArtist($0) && seen.insert(LibraryCheck.artistKey($0)).inserted
                    }, q, SearchRanker.score(notYetArtist:_:))
                    let room = limit - rows.count
                    rows += fresh.prefix(room)
                    paging.queued.artists += fresh.dropFirst(room)
                } else {
                    paging.cursor.aurralArtistsOffset = nil
                }
            }
            result.artists = rows
        case .albums:
            let limit = Self.limits.albums
            var rows = Self.take(&paging.queued.albums, limit)
            if rows.count < limit, let offset = paging.cursor.aurralAlbumsOffset {
                if let fetch = outsideMore.albums {
                    let page = try await Self.withDeadline(outsideMore.timeout, sleep: sleep) { try await fetch(query, offset) }
                    paging.cursor.aurralAlbumsOffset = page.next
                    var seen = Set((band.albums + rows + paging.queued.albums).map(LibraryCheck.albumKey))
                    let fresh = SearchRanker.rank(page.items.filter {
                        !$0.title.isEmpty && !check.hasAlbum($0) && seen.insert(LibraryCheck.albumKey($0)).inserted
                    }, q, SearchRanker.score(notYetAlbum:_:))
                    let room = limit - rows.count
                    rows += fresh.prefix(room)
                    paging.queued.albums += fresh.dropFirst(room)
                } else {
                    paging.cursor.aurralAlbumsOffset = nil
                }
            }
            result.albums = rows
        }
        result.paging = paging
        return result
    }

    static func take<T>(_ queue: inout [T], _ n: Int) -> [T] {
        let head = Array(queue.prefix(n))
        queue.removeFirst(head.count)
        return head
    }
}

extension SearchSections {
    /// The band has another page of this kind.
    public func hasMoreOutside(_ kind: OutsideKind) -> Bool { outside?.hasMore(kind) ?? false }

    /// Adds a band Load more's rows at the end of their kind (rows on screen never move) and takes that kind's paging.
    public mutating func append(_ more: OutsideMoreResults) {
        guard var outside, outside.query == more.paging.query else { return }
        switch more.kind {
        case .songs:
            var seen = Set(notYet.songs.flatMap(LibraryCheck.songKeys))
            notYet.songs += more.songs.filter { r in
                let keys = LibraryCheck.songKeys(r)
                guard keys.allSatisfy({ !seen.contains($0) }) else { return false }
                seen.formUnion(keys)
                return true
            }
            var ids = Set(notYet.owned.map(\.songId))
            notYet.owned += more.owned.filter { ids.insert($0.songId).inserted }
        case .artists:
            var seen = Set(notYet.artists.map(LibraryCheck.artistKey))
            notYet.artists += more.artists.filter { seen.insert(LibraryCheck.artistKey($0)).inserted }
        case .albums:
            var seen = Set(notYet.albums.map(LibraryCheck.albumKey))
            notYet.albums += more.albums.filter { seen.insert(LibraryCheck.albumKey($0)).inserted }
        }
        outside.take(more.kind, from: more.paging)
        self.outside = outside
    }
}
