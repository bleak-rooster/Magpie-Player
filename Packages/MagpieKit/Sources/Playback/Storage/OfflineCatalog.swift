import Foundation
import MagpieCore

/// What's on the phone, browsable with no server (spec §6, "Offline metadata"): the downloads by album, artist,
/// playlist, song and genre, built from the snapshots kept beside the files, plus the cached songs that have played
/// ("Recently played on this phone"). Cached songs are never listed as downloads. A value made from one read of the
/// store; it is not a mirror of the server library.
///
/// An album or artist the server gave no id is grouped by its name (an album by title and artist) under a local id
/// (`isLocalId`), which only this catalog knows.
///
/// Round 28 O2 (owner, 2026-11-15, item 1): pages read online leave records (`OfflineRecords`, D331): an album's header,
/// its server order and count; an artist's name, picture and album order; a playlist's owner and kind. The catalogue
/// uses them where they exist and the songs' snapshots otherwise. An album's artist is its record's, else its songs'
/// album artist, else (as before) its first track's; artists are album artists and track artists. Only downloads are
/// listed; cached songs never are.
public struct OfflineCatalog: Sendable {
    private let downloads: [AudioEntry]
    private let cache: [AudioEntry]
    private let savedPlaylists: [DownloadedPlaylist]
    private let records: OfflineRecords

    public init(entries: [AudioEntry], playlists: [DownloadedPlaylist], records: OfflineRecords = OfflineRecords()) {
        downloads = entries.filter { $0.kind == .download }
        cache = entries.filter { $0.kind == .cache }
        savedPlaylists = playlists
        self.records = records
    }

    /// Ids made here for albums and artists the server gave none.
    static let localPrefix = "magpie.local:"

    /// Whether `id` was made by this catalog (an album or artist without a server id).
    public static func isLocalId(_ id: String) -> Bool { id.hasPrefix(localPrefix) }

    // MARK: - Albums

    /// The downloads grouped by album, sorted by name (case-insensitive).
    public func albums() -> [Album] {
        albumGroups().map { makeAlbum(id: $0.key, $0.value) }
            .sorted { Self.ordered($0.name, $0.id, $1.name, $1.id) }
    }

    /// The album with its downloaded songs, ordered by disc and track.
    public func album(id: String) -> Album? {
        let songs = downloads.map(\.metadata).filter { Self.albumKey($0) == id }
        return songs.isEmpty ? nil : makeAlbum(id: id, songs)
    }

    /// The downloaded albums of the artist with `id` (from `artists()`): albums with a song by them, and (round 28 O2)
    /// albums they are the album artist of.
    public func albums(byArtist id: String) -> [Album] {
        albums().filter { album in
            Self.artistKey(album.artistId, album.artist) == id
                || album.songs?.contains { Self.artistKey($0.artistId, $0.artist) == id } == true
        }
    }

    /// Round 28 O2 (D331): an album's page: the header from its record (else from its songs), the songs on the phone in
    /// the server's order (else by disc and track; songs the server no longer lists come last, D55), how many are on the
    /// phone and how many the album has (nil when not known). Nil when none of its songs is downloaded.
    public func albumPage(id: String) -> OfflineAlbumPage? {
        let metas = downloads.map(\.metadata).filter { Self.albumKey($0) == id }
        guard !metas.isEmpty else { return nil }
        var album = makeAlbum(id: id, metas)
        let record = records.albums[id]
        if let record, let songs = album.songs {
            let position = Dictionary(record.songIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            album.songs = songs.enumerated().sorted { a, b in
                (position[a.element.id] ?? Int.max, a.offset) < (position[b.element.id] ?? Int.max, b.offset)
            }.map(\.element)
        }
        let onPhone = metas.count
        let known = record?.songCount ?? metas.compactMap(\.albumSongCount).max()
        let genre = record?.genre ?? metas.lazy.compactMap { $0.genre?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return OfflineAlbumPage(album: album, genre: genre, compilation: record?.compilation ?? false, onPhone: onPhone,
                                total: known.map { max($0, onPhone) })
    }

    /// The downloaded album and artist pages a downloaded song belongs to (their ids here), or nil when it isn't
    /// downloaded (round 11 R10: Now Playing's links offline).
    public func pages(ofSong songId: String) -> (albumId: String, artistId: String)? {
        guard let meta = downloads.first(where: { $0.songId == songId })?.metadata else { return nil }
        return (Self.albumKey(meta), Self.artistKey(meta.artistId, meta.artist))
    }

    // MARK: - Recently downloaded (round 12 Y3)

    /// One "Recently downloaded" tile: an album, or a downloaded playlist as itself.
    public enum RecentDownload: Sendable, Hashable, Identifiable {
        case album(Album)
        case playlist(Playlist)

        public var id: String {
            switch self {
            case .album(let album): "album-\(album.id)"
            case .playlist(let playlist): "playlist-\(playlist.id)"
            }
        }
    }

    /// The downloads newest first, by when their songs landed (the latest song of each). A downloaded playlist is
    /// listed as itself; a song held only by playlists makes no album tile, so a playlist never shows up as the
    /// partial albums its songs come from. The same moment: by name, then id.
    public func recentlyDownloaded() -> [RecentDownload] {
        var dated: [(item: RecentDownload, at: Date, name: String)] = []
        let listed = Set(savedPlaylists.map(\.id))
        let ownAlbum = downloads.filter { entry in
            entry.reasons.contains { reason in
                if case .playlist(let id) = reason { return !listed.contains(id) }   // a playlist no longer saved
                return true
            }
        }
        for (id, entries) in Dictionary(grouping: ownAlbum, by: { Self.albumKey($0.metadata) }) {
            let album = makeAlbum(id: id, entries.map(\.metadata))
            dated.append((.album(album), entries.map(\.downloadedAt).max()!, album.name))
        }
        let landed = Dictionary(downloads.map { ($0.songId, $0.downloadedAt) }, uniquingKeysWith: max)
        for playlist in playlists() {
            let ids = savedPlaylists.first { $0.id == playlist.id }?.songIds ?? []
            guard let at = ids.compactMap({ landed[$0] }).max() else { continue }
            dated.append((.playlist(playlist), at, playlist.name))
        }
        return dated.sorted { a, b in
            if a.at != b.at { return a.at > b.at }
            return Self.ordered(a.name, a.item.id, b.name, b.item.id)
        }.map(\.item)
    }

    // MARK: - Artists

    /// The artists of the downloads, sorted by name; `albumCount` counts their downloaded albums. Round 28 O2: album
    /// artists as well as track artists, with a recorded artist's name and picture.
    public func artists() -> [Artist] {
        var names: [String: String] = [:]
        var albums: [String: Set<String>] = [:]
        for (albumId, songs) in albumGroups().sorted(by: { $0.key < $1.key }) {
            let album = makeAlbum(id: albumId, songs)
            let key = Self.artistKey(album.artistId, album.artist)
            if names[key] == nil { names[key] = album.artist }
            albums[key, default: []].insert(albumId)
        }
        for meta in downloads.map(\.metadata).sorted(by: { $0.songId < $1.songId }) {
            let key = Self.artistKey(meta.artistId, meta.artist)
            if names[key] == nil { names[key] = meta.artist }
            albums[key, default: []].insert(Self.albumKey(meta))
        }
        return names.map { id, name in
            let record = records.artists[id]
            return Artist(id: id, name: record?.name ?? name, albumCount: albums[id]?.count ?? 0, coverArtId: record?.coverArtId)
        }
        .sorted { Self.ordered($0.name, $0.id, $1.name, $1.id) }
    }

    /// Round 28 O2 (D331): an artist's page, for an album-artist id or a track-artist id: the albums with a song on the
    /// phone where they are the album artist (in the recorded order, else by name), then the songs on the phone where
    /// they are only the track artist ("Songs on this phone"). Nil when neither has anything.
    public func artistPage(id: String) -> OfflineArtistPage? {
        var own = albums().filter { Self.artistKey($0.artistId, $0.artist) == id }
        let record = records.artists[id]
        if let record {
            let position = Dictionary(record.albumIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            own = own.enumerated().sorted { a, b in
                (position[a.element.id] ?? Int.max, a.offset) < (position[b.element.id] ?? Int.max, b.offset)
            }.map(\.element)
        }
        let ownIds = Set(own.map(\.id))
        let featured = downloads.map(\.metadata)
            .filter { Self.artistKey($0.artistId, $0.artist) == id && !ownIds.contains(Self.albumKey($0)) }
            .map(Self.song)
            .sorted { Self.ordered($0.title, $0.id, $1.title, $1.id) }
        guard !own.isEmpty || !featured.isEmpty else { return nil }
        let name = record?.name ?? own.first?.artist ?? featured.first?.artist ?? ""
        return OfflineArtistPage(artist: Artist(id: id, name: name, albumCount: own.count, coverArtId: record?.coverArtId),
                                 albums: own, songs: featured)
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

    /// Round 28 O2 (D331, per Q3): the downloaded playlists and, `includingRecorded`, the playlists read online that
    /// hold a download, in one A to Z list, each once (with its newer copy's name and owner). Flows and Discover's
    /// shared playlists are kept out (D185: they're Discover's; `AppModel.offlineFlows` lists flows).
    public func playlists(includingRecorded: Bool) -> [Playlist] {
        var ids = savedPlaylists.map(\.id)
        if includingRecorded { ids += records.playlists.keys.sorted() }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
            .compactMap(playlistPage)
            .filter { $0.kind == .playlist }
            .map(\.playlist)
            .sorted { Self.ordered($0.name, $0.id, $1.name, $1.id) }
    }

    /// Round 28 O2 (D331): a playlist's page: its name, owner and kind, the songs on the phone in its order, how many
    /// are on the phone and how many it has. From the downloaded copy or the record, whichever was saved later. Nil when
    /// none of its songs is downloaded.
    public func playlistPage(id: String) -> OfflinePlaylistPage? {
        let saved = savedPlaylists.first { $0.id == id }
        let recorded = records.playlists[id]
        guard var base = [saved, recorded].compactMap({ $0 }).max(by: { $0.savedAt < $1.savedAt }) else { return nil }
        let other = base == saved ? recorded : saved
        base.owner = base.owner ?? other?.owner
        base.kind = base.kind ?? other?.kind
        base.changed = base.changed ?? other?.changed
        let byId = Dictionary(downloads.map { ($0.songId, $0.metadata) }, uniquingKeysWith: { a, _ in a })
        let songs = base.songIds.compactMap { byId[$0].map(Self.song) }
        guard !songs.isEmpty else { return nil }
        let playlist = Playlist(id: id, name: base.name, songCount: songs.count, duration: songs.reduce(0) { $0 + $1.duration },
                                coverArtId: base.coverArtId, owner: base.owner, changed: base.changed)
        return OfflinePlaylistPage(playlist: playlist, kind: base.kind ?? .playlist, songs: songs, onPhone: songs.count,
                                   total: max(base.songIds.count, songs.count))
    }

    /// Round 28 O2: a downloaded song as the catalogue shows it; nil when it isn't a download.
    public func song(id: String) -> Song? {
        downloads.first { $0.songId == id }.map { Self.song($0.metadata) }
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

    private func albumGroups() -> [String: [AudioMetadata]] {
        Dictionary(grouping: downloads.map(\.metadata), by: Self.albumKey)
    }

    /// An album of downloaded songs (`songs` not empty), ordered by disc and track. Round 28 O2: the header from its
    /// record when there is one; the album artist from the record, else from a song that knows it, else the first
    /// track's artist (as before).
    private func makeAlbum(id: String, _ songs: [AudioMetadata]) -> Album {
        let ordered = songs.sorted {
            ($0.disc ?? 1, $0.track ?? Int.max, $0.title, $0.songId) < ($1.disc ?? 1, $1.track ?? Int.max, $1.title, $1.songId)
        }
        let first = ordered[0]
        let record = records.albums[id]
        let known = ordered.first { $0.albumArtist != nil }
        let artist = record?.artist ?? known?.albumArtist ?? first.artist
        let artistId = record.map(\.artistId) ?? known.map(\.albumArtistId) ?? first.artistId
        let cover = record?.coverArtId ?? ordered.lazy.compactMap(\.albumCoverArtId).first
            ?? ordered.lazy.compactMap(\.coverArtId).first
        return Album(id: id, name: record?.name ?? first.album, artist: artist, artistId: artistId, year: record?.year,
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

/// Round 28 O2 (D331): an album page from the phone. `total` is the album's song count when known (from its record, or
/// the count saved with an album download), never less than `onPhone`.
public struct OfflineAlbumPage: Sendable, Hashable {
    public var album: Album
    public var genre: String?
    public var compilation: Bool
    public var onPhone: Int
    public var total: Int?

    public init(album: Album, genre: String?, compilation: Bool, onPhone: Int, total: Int?) {
        self.album = album; self.genre = genre; self.compilation = compilation; self.onPhone = onPhone; self.total = total
    }

    /// Fewer of its songs on the phone than it has.
    public var isPartial: Bool { total.map { onPhone < $0 } ?? false }
}

/// Round 28 O2 (D331): an artist page from the phone: `albums` where they are the album artist, `songs` where they are
/// only the track artist.
public struct OfflineArtistPage: Sendable, Hashable {
    public var artist: Artist
    public var albums: [Album]
    public var songs: [Song]

    public init(artist: Artist, albums: [Album], songs: [Song]) {
        self.artist = artist; self.albums = albums; self.songs = songs
    }
}

/// Round 28 O2 (D331): a playlist (or flow) page from the phone; `total` is how many songs it has.
public struct OfflinePlaylistPage: Sendable, Hashable {
    public var playlist: Playlist
    public var kind: OfflinePlaylistKind
    public var songs: [Song]
    public var onPhone: Int
    public var total: Int?

    public init(playlist: Playlist, kind: OfflinePlaylistKind, songs: [Song], onPhone: Int, total: Int?) {
        self.playlist = playlist; self.kind = kind; self.songs = songs; self.onPhone = onPhone; self.total = total
    }

    public var isPartial: Bool { total.map { onPhone < $0 } ?? false }
}
