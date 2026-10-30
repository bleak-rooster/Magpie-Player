import DesignSystem
import Foundation
import MagpieCore
import Playback

/// What's on the phone as a download, indexed for the Downloaded marks (P1). Rebuilt from the store's entries and
/// playlist snapshots whenever the manager refreshes its mirrors, so marks update live as downloads land or leave.
/// Cached (pre-downloaded) songs never count.
struct DownloadIndex: Equatable {
    private(set) var songs: Set<String> = []
    private var byAlbum: [String: Set<String>] = [:]
    private var byArtist: [String: Set<String>] = [:]
    /// Per artist, the albums with songs downloaded as that album (the album reason).
    private var albumDownloadsByArtist: [String: Set<String>] = [:]
    /// Per album downloaded as an album, its song count then (the largest recorded).
    private var albumSongCounts: [String: Int] = [:]
    private var playlists: [String: [String]] = [:]

    init() {}

    init(entries: [AudioEntry], playlists: [DownloadedPlaylist]) {
        for entry in entries where entry.kind == .download {
            let id = entry.songId, meta = entry.metadata
            songs.insert(id)
            if let album = meta.albumId { byAlbum[album, default: []].insert(id) }
            if let artist = meta.artistId {
                byArtist[artist, default: []].insert(id)
                for case let .album(album) in entry.reasons {
                    albumDownloadsByArtist[artist, default: []].insert(album)
                    if let count = meta.albumSongCount { albumSongCounts[album] = max(albumSongCounts[album] ?? 0, count) }
                }
            }
        }
        for playlist in playlists { self.playlists[playlist.id] = playlist.songIds }
    }

    func isDownloaded(_ songId: String) -> Bool { songs.contains(songId) }

    /// Over a known list of songs (an album's or playlist's page).
    func mark(songIds: [String]) -> DownloadMark {
        let unique = Set(songIds)
        return .counting(done: unique.filter(songs.contains).count, total: unique.count)
    }

    /// An album tile or row: its songs listed when known, otherwise the downloaded songs of the album against its
    /// song count.
    func mark(album: Album) -> DownloadMark {
        if let listed = album.songs, !listed.isEmpty { return mark(songIds: listed.map(\.id)) }
        let done = byAlbum[album.id]?.count ?? 0
        return .counting(done: done, total: max(album.songCount, done))
    }

    /// A playlist: its songs when known (its page); otherwise the snapshot kept when it was downloaded. A playlist
    /// never downloaded as such has no snapshot, so its tile shows no mark.
    func mark(playlistId: String, songIds: [String]? = nil) -> DownloadMark {
        if let songIds { return mark(songIds: songIds) }
        guard let saved = playlists[playlistId] else { return .none }
        return mark(songIds: saved)
    }

    /// An artist's page: the artist's songs Magpie knows of, from the downloads index and the artist's albums.
    func mark(artistId: String, albums: [Album]) -> DownloadMark {
        let albumIds = Set(albums.map(\.id))
        var done = byArtist[artistId] ?? []
        for id in albumIds { done.formUnion(byAlbum[id] ?? []) }
        let total = albums.reduce(0) { $0 + max($1.songCount, 0) }
        return .counting(done: done.count, total: max(total, done.count))
    }

    /// The artist list, where the full song count isn't known: "Downloaded" only when as many albums as the artist has
    /// were downloaded as albums and every one of them is whole (all the songs it had then are on the phone); anything
    /// less is "Some downloaded" (review I2). An album saved without its count can't be shown whole.
    func listMark(artist: Artist) -> DownloadMark {
        guard byArtist[artist.id]?.isEmpty == false else { return .none }
        let albums = albumDownloadsByArtist[artist.id] ?? []
        let whole = albums.filter { album in
            guard let count = albumSongCounts[album], count > 0 else { return false }
            return (byAlbum[album]?.count ?? 0) >= count
        }
        return artist.albumCount > 0 && whole.count >= artist.albumCount ? .downloaded : .some
    }
}
