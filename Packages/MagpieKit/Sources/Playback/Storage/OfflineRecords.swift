import Foundation
import MagpieCore

/// Round 28 O2 (owner, 2026-11-15, item 1: "anything that is downloaded should be cached and only updated when in
/// online mode. This should work for artists, albums, songs, playlists, flows"): what album, artist and playlist pages
/// showed the last time they were read online, kept beside the downloads so offline pages look like the server's
/// (D331, D333).
///
/// `Audio/<scope>/records.json`, version 1, written atomically by `AudioStore` (kept out of backups, readable after
/// first unlock), erased with the scope at sign-out and with "Remove all downloads". Only what pages show, ids, owners'
/// usernames and dates: **never a URL, token, salt, server address or password** (plan §4). Pure: the model, its
/// bounds, and the prune; the store does the file.
public struct OfflineRecords: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// D331's bounds. A file bigger than `maxBytes` reads as none (the catalogue falls back to the songs' snapshots);
    /// past a count, the records saved longest ago go first.
    public static let maxAlbums = 5_000
    public static let maxArtists = 2_000
    public static let maxPlaylists = 300
    public static let maxBytes = 8 * 1024 * 1024
    public static let maxAlbumSongs = 500
    public static let maxArtistAlbums = 500
    public static let maxPlaylistSongs = 2_000
    /// A name, artist or genre longer than this is cut (a server can send anything).
    public static let maxText = 500

    public var version = OfflineRecords.currentVersion
    public var albums: [String: AlbumRecord] = [:]
    public var artists: [String: ArtistRecord] = [:]
    /// The playlist record is a `DownloadedPlaylist` with its owner, kind and `changed` (D331).
    public var playlists: [String: DownloadedPlaylist] = [:]

    public init() {}

    public var isEmpty: Bool { albums.isEmpty && artists.isEmpty && playlists.isEmpty }

    // MARK: - Records

    /// An album page's header as read online, and the server's song order and count.
    public struct AlbumRecord: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var artist: String
        public var artistId: String?
        public var year: Int?
        public var genre: String?
        /// How many songs the album has on the server (not on the phone).
        public var songCount: Int
        public var duration: TimeInterval
        public var coverArtId: String?
        /// Its songs are by more than one track artist, not all of them the album artist.
        public var compilation: Bool
        /// The server's song order, at most `maxAlbumSongs`.
        public var songIds: [String]
        public var savedAt: Date

        /// The record of `album` as read with `songs` (the page's songs, in the server's order).
        public init(album: Album, songs: [Song], savedAt: Date) {
            id = album.id
            name = OfflineRecords.text(album.name)
            artist = OfflineRecords.text(album.artist)
            artistId = album.artistId
            year = album.year ?? album.originalYear
            let genres = songs.compactMap { $0.genre?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            genre = genres.first.map(OfflineRecords.text)
            songCount = max(0, max(album.songCount, songs.count))
            duration = OfflineRecords.length(album.duration)
            coverArtId = album.coverArtId
            let trackArtists = Set(songs.map { $0.artistId ?? $0.artist })
            compilation = trackArtists.count > 1 && songs.contains { ($0.artistId ?? $0.artist) != (album.artistId ?? album.artist) }
            songIds = Array(songs.map(\.id).prefix(OfflineRecords.maxAlbumSongs))
            self.savedAt = savedAt
        }

        /// Whether it shows the same as `other` (when it was saved doesn't count).
        public func showsSame(as other: AlbumRecord) -> Bool {
            var a = self, b = other
            a.savedAt = .distantPast; b.savedAt = .distantPast
            return a == b
        }
    }

    /// An artist page's header and the server's album order.
    public struct ArtistRecord: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var coverArtId: String?
        /// The server's album order, at most `maxArtistAlbums`.
        public var albumIds: [String]
        public var savedAt: Date

        public init(artist: Artist, albums: [Album], savedAt: Date) {
            id = artist.id
            name = OfflineRecords.text(artist.name)
            coverArtId = artist.coverArtId
            albumIds = Array(albums.map(\.id).prefix(OfflineRecords.maxArtistAlbums))
            self.savedAt = savedAt
        }

        public func showsSame(as other: ArtistRecord) -> Bool {
            var a = self, b = other
            a.savedAt = .distantPast; b.savedAt = .distantPast
            return a == b
        }
    }

    /// The record of `playlist` as read with `songs` (its order), as `kind`.
    public static func playlistRecord(_ playlist: Playlist, songs: [Song], kind: OfflinePlaylistKind,
                                      savedAt: Date) -> DownloadedPlaylist {
        DownloadedPlaylist(id: playlist.id, name: text(playlist.name), coverArtId: playlist.coverArtId,
                           songIds: Array(songs.map(\.id).prefix(maxPlaylistSongs)), savedAt: savedAt,
                           owner: playlist.owner.map(text), kind: kind, changed: playlist.changed)
    }

    /// Whether two playlist records show the same (when they were saved doesn't count).
    public static func showsSame(_ a: DownloadedPlaylist, _ b: DownloadedPlaylist) -> Bool {
        var a = a, b = b
        a.savedAt = .distantPast; b.savedAt = .distantPast
        return a == b
    }

    // MARK: - Prune and bounds

    /// Only the records a download still needs (D333): an album with a downloaded song (by album id, or one of its
    /// songs), an artist with a downloaded song (as track or album artist, or on one of their albums), a playlist
    /// holding a downloaded song.
    public func pruned(downloads: [AudioMetadata]) -> OfflineRecords {
        let songIds = Set(downloads.map(\.songId))
        let albumIds = Set(downloads.compactMap(\.albumId))
        let artistIds = Set(downloads.compactMap(\.artistId) + downloads.compactMap(\.albumArtistId))
        var copy = self
        copy.albums = albums.filter { id, record in albumIds.contains(id) || record.songIds.contains(where: songIds.contains) }
        let keptAlbums = Set(copy.albums.keys).union(albumIds)
        copy.artists = artists.filter { id, record in
            artistIds.contains(id) || record.albumIds.contains(where: keptAlbums.contains)
                || copy.albums.values.contains { $0.artistId == id }
        }
        copy.playlists = playlists.filter { _, record in record.songIds.contains(where: songIds.contains) }
        return copy
    }

    /// Every cover a record names (for `AudioStore.pruneCovers`).
    public var coverIds: Set<String> {
        Set(albums.values.compactMap(\.coverArtId) + artists.values.compactMap(\.coverArtId)
            + playlists.values.compactMap(\.coverArtId))
    }

    /// Within every bound: each record's lists, then the counts (the records saved longest ago go first), then the
    /// size (the oldest go until the file fits). Records whose key isn't their id are dropped.
    public func bounded() -> OfflineRecords {
        var copy = self
        copy.version = Self.currentVersion
        copy.albums = albums.filter { $0.key == $0.value.id }.mapValues { record in
            var r = record
            r.songIds = Array(r.songIds.prefix(Self.maxAlbumSongs))
            r.songCount = max(0, r.songCount)
            r.duration = Self.length(r.duration)
            return r
        }
        copy.artists = artists.filter { $0.key == $0.value.id }.mapValues { record in
            var r = record
            r.albumIds = Array(r.albumIds.prefix(Self.maxArtistAlbums))
            return r
        }
        copy.playlists = playlists.filter { $0.key == $0.value.id }.mapValues { record in
            var r = record
            r.songIds = Array(r.songIds.prefix(Self.maxPlaylistSongs))
            return r
        }
        copy.albums = Self.newest(copy.albums, Self.maxAlbums, \.savedAt)
        copy.artists = Self.newest(copy.artists, Self.maxArtists, \.savedAt)
        copy.playlists = Self.newest(copy.playlists, Self.maxPlaylists, \.savedAt)
        // The size: drop the oldest tenth of what's left until it fits (bounded: at most 64 passes).
        var passes = 0
        while passes < 64, let size = copy.encoded()?.count, size > Self.maxBytes, !copy.isEmpty {
            passes += 1
            copy.dropOldest(max(1, copy.count / 10))
        }
        if let size = copy.encoded()?.count, size > Self.maxBytes { return OfflineRecords() }
        return copy
    }

    /// The saved file, or nil when it is too big, another version, or doesn't read (D331: reads as none).
    public static func decode(_ data: Data) -> OfflineRecords? {
        guard data.count <= maxBytes,
              let records = try? JSONDecoder().decode(OfflineRecords.self, from: data),
              records.version == currentVersion else { return nil }
        return records.bounded()
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    var count: Int { albums.count + artists.count + playlists.count }

    private mutating func dropOldest(_ n: Int) {
        enum Key { case album(String), artist(String), playlist(String) }
        let dated: [(Date, String, Key)] = albums.map { ($0.value.savedAt, "a" + $0.key, .album($0.key)) }
            + artists.map { ($0.value.savedAt, "r" + $0.key, .artist($0.key)) }
            + playlists.map { ($0.value.savedAt, "p" + $0.key, .playlist($0.key)) }
        for (_, _, key) in dated.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }).prefix(n) {
            switch key {
            case .album(let id): albums[id] = nil
            case .artist(let id): artists[id] = nil
            case .playlist(let id): playlists[id] = nil
            }
        }
    }

    private static func newest<T>(_ records: [String: T], _ limit: Int, _ date: KeyPath<T, Date>) -> [String: T] {
        guard records.count > limit else { return records }
        let kept = records.sorted { ($0.value[keyPath: date], $0.key) > ($1.value[keyPath: date], $1.key) }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    static func text(_ s: String) -> String { s.count > maxText ? String(s.prefix(maxText)) : s }

    /// A length JSON can hold: finite and not negative.
    static func length(_ t: TimeInterval) -> TimeInterval { t.isFinite ? max(0, t) : 0 }
}

// MARK: - The file (AudioStore)

/// Round 28 O2 (owner, 2026-11-15): the records file, the song snapshots' refresh and the covers' prune (D331–D334).
/// Every write needs the store ready (after first unlock) and a records file that has been read: one that couldn't be
/// read yet is never written over.
extension AudioStore {
    /// Round 28 O2: what a record write did (D333).
    public enum RecordOutcome: Sendable, Equatable {
        /// Saved (it was new or showed something different).
        case written
        /// The same as the saved one: nothing written.
        case unchanged
        /// None of the page's songs is a download: nothing written.
        case noDownload
    }

    static let recordsName = "records.json"
    nonisolated var recordsURL: URL { directory.appending(path: Self.recordsName) }

    /// The records as saved (none when there's no file, it is too big or damaged, or it can't be read yet).
    public func records() -> OfflineRecords { (try? loadedRecords()) ?? OfflineRecords() }

    /// Saves an album page's record when one of its songs is a download (by album id or by song) and it shows
    /// something different from the saved one.
    @discardableResult
    public func recordAlbum(_ record: OfflineRecords.AlbumRecord) throws -> RecordOutcome {
        try ensureReady()
        let songIds = Set(record.songIds)
        guard downloadMetadata().contains(where: { $0.albumId == record.id || songIds.contains($0.songId) }) else {
            return .noDownload
        }
        return try changeRecords { records in
            if let saved = records.albums[record.id], saved.showsSame(as: record) { return false }
            records.albums[record.id] = record
            return true
        }
    }

    /// Saves an artist page's record when one of their songs (as track or album artist) or albums is a download.
    @discardableResult
    public func recordArtist(_ record: OfflineRecords.ArtistRecord) throws -> RecordOutcome {
        try ensureReady()
        let albums = Set(record.albumIds)
        guard downloadMetadata().contains(where: {
            $0.artistId == record.id || $0.albumArtistId == record.id || $0.albumId.map(albums.contains) == true
        }) else { return .noDownload }
        return try changeRecords { records in
            if let saved = records.artists[record.id], saved.showsSame(as: record) { return false }
            records.artists[record.id] = record
            return true
        }
    }

    /// Saves a playlist page's record when it holds a download (per Q3, downloaded as a whole or not).
    @discardableResult
    public func recordPlaylist(_ record: DownloadedPlaylist) throws -> RecordOutcome {
        try ensureReady()
        let downloads = Set(downloadMetadata().map(\.songId))
        guard record.songIds.contains(where: downloads.contains) else { return .noDownload }
        var bounded = record
        bounded.songIds = Array(record.songIds.prefix(OfflineRecords.maxPlaylistSongs))
        return try changeRecords { records in
            if let saved = records.playlists[record.id], OfflineRecords.showsSame(saved, bounded) { return false }
            records.playlists[record.id] = bounded
            return true
        }
    }

    /// D332: rewrites a download's snapshot when a page read online shows it differently (title, artist, album, track,
    /// disc, genre, cover, album artist). What describes the file on the phone (format, bit rate, length, gain), the
    /// album cover and count saved with it, its quality, reasons and dates stay. An album artist not given keeps the one
    /// known. Returns whether it was rewritten; a cached song or one not stored is left alone.
    @discardableResult
    public func refreshMetadata(_ song: Song, albumArtist: String? = nil, albumArtistId: String? = nil) throws -> Bool {
        try ensureReady()
        guard var entry = index.entries[song.id], entry.kind == .download else { return false }
        var meta = entry.metadata
        meta.title = song.title; meta.artist = song.artist; meta.artistId = song.artistId
        meta.album = song.album; meta.albumId = song.albumId; meta.track = song.track; meta.disc = song.disc
        meta.genre = song.genre; meta.coverArtId = song.coverArtId
        if let albumArtist { meta.albumArtist = OfflineRecords.text(albumArtist); meta.albumArtistId = albumArtistId }
        guard meta != entry.metadata else { return false }
        entry.metadata = meta
        try store(entry)
        return true
    }

    /// D334: deletes every saved cover no download, downloaded playlist or record names, nor `keeping` (covers the
    /// caller still needs: downloads under way). Returns how many went. Nothing goes while the records can't be read.
    @discardableResult
    public func pruneCovers(keeping: Set<String>) -> Int {
        guard (try? ensureReady()) != nil, let records = try? loadedRecords() else { return 0 }
        let downloads = downloadMetadata()
        let named = keeping.union(downloads.compactMap(\.coverArtId)).union(downloads.compactMap(\.albumCoverArtId))
            .union(index.playlists.values.compactMap(\.coverArtId)).union(records.coverIds)
        let kept = Set(named.map { Self.sha256($0) + ".jpg" })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: coversDirectory.path)) ?? []
        var removed = 0
        for name in names where name.wholeMatch(of: /[0-9a-f]{64}\.jpg/) != nil && !kept.contains(name) {
            if (try? FileManager.default.removeItem(at: coversDirectory.appending(path: name))) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Internal

    /// The downloads' snapshots (never the cache's).
    func downloadMetadata() -> [AudioMetadata] {
        index.entries.values.filter { $0.kind == .download }.map(\.metadata)
    }

    /// The records, read once. Throws `notReady` when the file is there but can't be read yet (before first unlock):
    /// nothing may be written over it then. A file that reads but is too big or damaged is none.
    func loadedRecords() throws -> OfflineRecords {
        if let recordsCache { return recordsCache }
        let url = recordsURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            recordsCache = OfflineRecords()
            return OfflineRecords()
        }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > OfflineRecords.maxBytes {
            recordsCache = OfflineRecords()
            return OfflineRecords()
        }
        let data: Data
        do {
            data = try reader(url)
        } catch {
            if Self.isPermissionError(error), !isProtectedDataAvailable() { throw AudioStoreError.notReady }
            recordsCache = OfflineRecords()   // unusable: none (a later write replaces it)
            return OfflineRecords()
        }
        let records = OfflineRecords.decode(data) ?? OfflineRecords()
        recordsCache = records
        return records
    }

    /// Changes the records and writes them (bounded, atomically, out of backups) when `change` says it changed them.
    func changeRecords(_ change: (inout OfflineRecords) -> Bool) throws -> RecordOutcome {
        var records = try loadedRecords()
        guard change(&records) else { return .unchanged }
        try writeRecords(records.bounded())
        return .written
    }

    func writeRecords(_ records: OfflineRecords) throws {
        let url = recordsURL
        if records.isEmpty {
            try? FileManager.default.removeItem(at: url)
            recordsCache = records
            return
        }
        try prepareDirectory()
        try AtomicFile.write(records, to: url)
        try protect(url)
        recordsCache = records
    }

    /// After a removal: records and lyrics no download needs any more go (D333, D336). Before the records can be
    /// read they're left as they are (pruned at the next removal).
    func pruneAfterRemoval() {
        let downloads = downloadMetadata()
        if let records = try? loadedRecords() {
            let pruned = records.pruned(downloads: downloads)
            if pruned != records { try? writeRecords(pruned) }
        }
        pruneLyrics(keeping: Set(downloads.map(\.songId)))
    }

    /// "Remove all downloads": the records and every kept lyric go.
    func clearRecordsAndLyrics() {
        try? FileManager.default.removeItem(at: recordsURL)
        try? FileManager.default.removeItem(at: lyricsDirectory)
        recordsCache = OfflineRecords()
    }
}
