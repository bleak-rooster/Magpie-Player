import Foundation
import MagpieCore

/// What's on the phone, browsable with no server (spec §6, "Offline metadata"): the downloads by album, artist,
/// playlist, song and genre, built from the snapshots kept beside the files, plus the cached songs that have played
/// ("Recently played on this phone"). Cached songs are never listed as downloads. A value made from one read of the
/// store; it is not a mirror of the server library.
///
/// An album or artist the server gave no id is grouped by its name (an album by title and artist) under a local id
/// (`isLocalId`), which only this catalog knows.
public struct OfflineCatalog: Sendable {
    private let downloads: [AudioEntry]
    private let cache: [AudioEntry]
    private let savedPlaylists: [DownloadedPlaylist]

    public init(entries: [AudioEntry], playlists: [DownloadedPlaylist]) {
        downloads = entries.filter { $0.kind == .download }
        cache = entries.filter { $0.kind == .cache }
        savedPlaylists = playlists
    }

    /// Ids made here for albums and artists the server gave none.
    static let localPrefix = "magpie.local:"

    /// Whether `id` was made by this catalog (an album or artist without a server id).
    public static func isLocalId(_ id: String) -> Bool { id.hasPrefix(localPrefix) }

    // MARK: - Albums

    /// The downloads grouped by album, sorted by name (case-insensitive).
    public func albums() -> [Album] {
        Dictionary(grouping: downloads.map(\.metadata), by: Self.albumKey)
            .map { Self.album(id: $0.key, $0.value) }
            .sorted { Self.ordered($0.name, $0.id, $1.name, $1.id) }
    }

    /// The album with its downloaded songs, ordered by disc and track.
    public func album(id: String) -> Album? {
        let songs = downloads.map(\.metadata).filter { Self.albumKey($0) == id }
        return songs.isEmpty ? nil : Self.album(id: id, songs)
    }

    /// The downloaded albums of the artist with `id` (from `artists()`).
    public func albums(byArtist id: String) -> [Album] {
        albums().filter { album in album.songs?.contains { Self.artistKey($0.artistId, $0.artist) == id } == true }
    }

    /// The downloaded album and artist pages a downloaded song belongs to (their ids here), or nil when it isn't
    /// downloaded (round 11 R10: Now Playing's links offline).
    public func pages(ofSong songId: String) -> (albumId: String, artistId: String)? {
        guard let meta = downloads.first(where: { $0.songId == songId })?.metadata else { return nil }
        return (Self.albumKey(meta), Self.artistKey(meta.artistId, meta.artist))
    }

    // MARK: - Artists

    /// The artists of the downloads, sorted by name; `albumCount` counts their downloaded albums.
    public func artists() -> [Artist] {
        Dictionary(grouping: downloads.map(\.metadata)) { Self.artistKey($0.artistId, $0.artist) }
            .map { id, songs in
                Artist(id: id, name: songs[0].artist, albumCount: Set(songs.map(Self.albumKey)).count)
            }
            .sorted { Self.ordered($0.name, $0.id, $1.name, $1.id) }
    }

    // MARK: - Playlists and songs

    /// The downloaded playlists that have songs on the phone, sorted by name.
    public func playlists() -> [Playlist] {
        savedPlaylists.compactMap { saved in
            let songs = songs(inPlaylist: saved.id)
            guard !songs.isEmpty else { return nil }
            return Playlist(id: saved.id, name: saved.name, songCount: songs.count,
                            duration: songs.reduce(0) { $0 + $1.duration }, coverArtId: saved.coverArtId)
        }
        .sorted { Self.ordered($0.name, $0.id, $1.name, $1.id) }
    }

    /// The playlist's songs in its order, skipping those not downloaded.
    public func songs(inPlaylist id: String) -> [Song] {
        guard let saved = savedPlaylists.first(where: { $0.id == id }) else { return [] }
        let byId = Dictionary(downloads.map { ($0.songId, $0.metadata) }, uniquingKeysWith: { a, _ in a })
        return saved.songIds.compactMap { byId[$0].map(Self.song) }
    }

    /// Every download, sorted by title.
    public func songs() -> [Song] {
        downloads.map { Self.song($0.metadata) }.sorted { Self.ordered($0.title, $0.id, $1.title, $1.id) }
    }

    /// The genres of the downloads, from their snapshots, sorted by name.
    public func genres() -> [Genre] {
        let tagged = downloads.map(\.metadata).compactMap { meta -> (String, AudioMetadata)? in
            guard let genre = meta.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty else { return nil }
            return (genre, meta)
        }
        return Dictionary(grouping: tagged, by: \.0)
            .map { name, songs in Genre(name: name, songCount: songs.count, albumCount: Set(songs.map { Self.albumKey($0.1) }).count) }
            .sorted { Self.ordered($0.name, $0.name, $1.name, $1.name) }
    }

    // MARK: - Search

    /// Downloads matching `query`, ignoring case and accents: songs by title, artist or album, albums by name or
    /// artist, artists by name. Empty for a blank query.
    public func search(_ query: String) -> LibrarySearchResult {
        let q = Self.fold(query)
        guard !q.isEmpty else { return LibrarySearchResult() }
        func has(_ text: String) -> Bool { Self.fold(text).contains(q) }
        return LibrarySearchResult(songs: songs().filter { has($0.title) || has($0.artist) || has($0.album) },
                                   albums: albums().filter { has($0.name) || has($0.artist) },
                                   artists: artists().filter { has($0.name) })
    }

    /// Cached songs that have played, newest play first, matching `query` like `search` (all of them when blank).
    public func recentlyPlayed(matching query: String) -> [Song] {
        let q = Self.fold(query)
        func has(_ text: String) -> Bool { Self.fold(text).contains(q) }
        return cache.filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed!, $1.songId) > ($1.lastPlayed!, $0.songId) }
            .map { Self.song($0.metadata) }
            .filter { q.isEmpty || has($0.title) || has($0.artist) || has($0.album) }
    }

    // MARK: - Private

    private static func albumKey(_ meta: AudioMetadata) -> String {
        meta.albumId ?? localPrefix + "album|" + meta.artist + "|" + meta.album
    }

    private static func artistKey(_ artistId: String?, _ name: String) -> String {
        artistId ?? localPrefix + "artist|" + name
    }

    private static func album(id: String, _ songs: [AudioMetadata]) -> Album {
        let ordered = songs.sorted {
            ($0.disc ?? 1, $0.track ?? Int.max, $0.title, $0.songId) < ($1.disc ?? 1, $1.track ?? Int.max, $1.title, $1.songId)
        }
        let first = ordered[0]
        let cover = ordered.lazy.compactMap(\.albumCoverArtId).first ?? ordered.lazy.compactMap(\.coverArtId).first
        return Album(id: id, name: first.album, artist: first.artist, artistId: first.artistId,
                     songCount: ordered.count, duration: ordered.reduce(0) { $0 + $1.duration },
                     coverArtId: cover, songs: ordered.map(Self.song))
    }

    /// The snapshot's song, showing the saved album cover when it was downloaded with its album (the song's own cover
    /// isn't saved).
    private static func song(_ meta: AudioMetadata) -> Song {
        var song = meta.song
        if let cover = meta.albumCoverArtId { song.coverArtId = cover }
        return song
    }

    /// By name ignoring case, then by id, so equal names keep a stable order.
    private static func ordered(_ a: String, _ aId: String, _ b: String, _ bId: String) -> Bool {
        switch a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: aId < bId
        }
    }

    private static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
