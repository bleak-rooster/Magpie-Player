import Foundation
import MagpieCore
import Testing
@testable import Playback

/// An entry as the store would hold it: a placeholder file name, size 1, `[.song]` for downloads and none for cache.
private func entry(_ id: String, title: String = "T", album: String, albumId: String?, artist: String = "A",
                   artistId: String? = "ar1", track: Int? = nil, genre: String? = nil, kind: AudioKind = .download,
                   lastPlayed: Date? = nil) -> AudioEntry {
    let song = Song(id: id, title: title, artist: artist, artistId: artistId, album: album, albumId: albumId,
                    track: track, duration: 60, genre: genre)
    return AudioEntry(songId: id, quality: .original, fileName: "\(id).mp3", size: 1, kind: kind,
                      reasons: kind == .download ? [.song] : [], downloadedAt: Date(timeIntervalSince1970: 0),
                      lastPlayed: lastPlayed, metadata: AudioMetadata(song))
}

@Suite struct OfflineCatalogTests {
    @Test func albumsGroupedAndSorted() {
        let c = OfflineCatalog(entries: [entry("s1", album: "b-album", albumId: "b", track: 2), entry("s2", album: "b-album", albumId: "b", track: 1),
                                         entry("s3", album: "A-album", albumId: "a", track: 1), entry("c1", album: "Z", albumId: "z", kind: .cache)],
                               playlists: [])
        #expect(c.albums().map(\.name) == ["A-album", "b-album"], "cache entries aren't downloads")
        #expect(c.album(id: "b")?.songs?.map(\.id) == ["s2", "s1"])
        #expect(c.album(id: "b")?.songCount == 2)
        #expect(c.artists().map(\.albumCount) == [2])
    }

    @Test func albumWithoutIdGroupsByTitleAndArtist() {
        let c = OfflineCatalog(entries: [entry("s1", album: "Loose", albumId: nil), entry("s2", album: "Loose", albumId: nil)], playlists: [])
        #expect(c.albums().count == 1 && c.albums()[0].songCount == 2)
        let id = c.albums()[0].id
        #expect(OfflineCatalog.isLocalId(id) && c.album(id: id)?.songs?.count == 2)
    }

    @Test func playlistsKeepOrder() {
        let p = DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: nil, songIds: ["s2", "s1", "gone"], savedAt: .now)
        let c = OfflineCatalog(entries: [entry("s1", album: "x", albumId: "x"), entry("s2", album: "x", albumId: "x")], playlists: [p])
        #expect(c.playlists().map(\.name) == ["Mix"])
        #expect(c.songs(inPlaylist: "p1").map(\.id) == ["s2", "s1"], "songs not on the phone are skipped")
    }

    @Test func searchFoldsCaseAndDiacritics() {
        let c = OfflineCatalog(entries: [entry("s1", title: "Minuit", album: "Café de la Mémoire", albumId: "c"),
                                         entry("s2", title: "Other", album: "Elsewhere", albumId: "e")], playlists: [])
        #expect(c.search("cafe").albums.map(\.name) == ["Café de la Mémoire"])
        #expect(c.search("MEMOIRE").songs.map(\.id) == ["s1"])
        #expect(c.search("minuit").songs.map(\.id) == ["s1"])
        #expect(c.search("zzz") == LibrarySearchResult())
    }

    @Test func genresCountedFromSnapshot() {
        let c = OfflineCatalog(entries: [entry("s1", album: "a", albumId: "a", genre: "Ambient"), entry("s2", album: "a", albumId: "a", genre: "Ambient"),
                                         entry("s3", album: "b", albumId: "b", genre: "Ambient"), entry("s4", album: "b", albumId: "b", genre: nil)],
                               playlists: [])
        #expect(c.genres() == [Genre(name: "Ambient", songCount: 3, albumCount: 2)])
    }

    @Test func recentlyPlayedOnlyCacheWithPlays() {
        let t = Date(timeIntervalSince1970: 100)
        let c = OfflineCatalog(entries: [entry("c1", title: "Old", album: "x", albumId: "x", kind: .cache, lastPlayed: t),
                                         entry("c2", title: "New", album: "x", albumId: "x", kind: .cache, lastPlayed: t + 10),
                                         entry("c3", album: "x", albumId: "x", kind: .cache),
                                         entry("d1", album: "x", albumId: "x", lastPlayed: t + 20)], playlists: [])
        #expect(c.recentlyPlayed(matching: "").map(\.id) == ["c2", "c1"])
        #expect(c.recentlyPlayed(matching: "old").map(\.id) == ["c1"])
    }

    @Test func artistsAndTheirAlbums() {
        let c = OfflineCatalog(entries: [entry("s1", album: "One", albumId: "1", artist: "Beta", artistId: "b"),
                                         entry("s2", album: "Two", albumId: "2", artist: "alpha", artistId: nil),
                                         entry("s3", album: "Three", albumId: "3", artist: "Beta", artistId: "b")], playlists: [])
        #expect(c.artists().map(\.name) == ["alpha", "Beta"])
        #expect(c.albums(byArtist: "b").map(\.name) == ["One", "Three"])
        let alpha = c.artists()[0].id
        #expect(OfflineCatalog.isLocalId(alpha) && c.albums(byArtist: alpha).map(\.name) == ["Two"])
        #expect(c.songs().map(\.id) == ["s1", "s2", "s3"])
    }

    /// Real-style ids: songs carry their own covers (`mf-…`), the saved cover is the album's (`al-…`).
    @Test func albumPrefersTheSavedAlbumCover() {
        var a = entry("s1", album: "x", albumId: "x", track: 1), b = entry("s2", album: "x", albumId: "x", track: 2)
        a.metadata.coverArtId = "mf-s1"; b.metadata.coverArtId = "mf-s2"
        b.metadata.albumCoverArtId = "al-x"
        let c = OfflineCatalog(entries: [a, b], playlists: [])
        #expect(c.albums()[0].coverArtId == "al-x")
        #expect(c.album(id: "x")?.songs?.map(\.coverArtId) == ["mf-s1", "al-x"])
        var loose = entry("s3", album: "y", albumId: "y"); loose.metadata.coverArtId = "mf-s3"
        #expect(OfflineCatalog(entries: [loose], playlists: []).albums()[0].coverArtId == "mf-s3", "no album cover: the song's")
    }
}
