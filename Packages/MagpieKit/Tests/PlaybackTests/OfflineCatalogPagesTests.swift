import Foundation
import MagpieCore
import Testing
@testable import Playback

/// Round 28 O2 (owner, 2026-11-15, item 1: "an album should still open the album of the downloaded music … In offline
/// mode, only downloaded songs are visible within albums, artists, songs"): the catalogue's pages from records and
/// snapshots (D331, D333).
@Suite struct OfflineCatalogPagesTests {
    static func meta(_ id: String, title: String? = nil, album: String = "al1", albumName: String = "Album",
                     artist: String = "Band", artistId: String? = "ar1", track: Int? = nil, disc: Int? = nil,
                     albumArtist: String? = nil, albumArtistId: String? = nil) -> AudioMetadata {
        var m = AudioMetadata(Song(id: id, title: title ?? "T\(id)", artist: artist, artistId: artistId, album: albumName,
                                   albumId: album, track: track, disc: disc, duration: 60, coverArtId: "mf-\(id)"))
        m.albumArtist = albumArtist
        m.albumArtistId = albumArtistId
        return m
    }

    static func entry(_ meta: AudioMetadata, kind: AudioKind = .download, at: TimeInterval = 0) -> AudioEntry {
        AudioEntry(songId: meta.songId, quality: .original, fileName: "\(meta.songId).mp3", size: 1, kind: kind,
                   reasons: kind == .download ? [.song] : [], downloadedAt: Date(timeIntervalSince1970: at), lastPlayed: nil,
                   metadata: meta)
    }

    static func song(_ id: String, artist: String = "Band", artistId: String = "ar1", album: String = "al1") -> Song {
        Song(id: id, title: "T\(id)", artist: artist, artistId: artistId, album: "Album", albumId: album, duration: 60)
    }

    @Test func catalog_partialAlbumShowsOnlyDownloadedWithCount() throws {
        var records = OfflineRecords()
        let server = ["s3", "s1", "s5", "s2", "s4"].map { Self.song($0) }
        records.albums["al1"] = .init(album: Album(id: "al1", name: "Recorded name", artist: "Band", artistId: "ar1",
                                                   year: 1999, songCount: 5, duration: 300, coverArtId: "al-al1"),
                                      songs: server, savedAt: .now)
        let c = OfflineCatalog(entries: [Self.entry(Self.meta("s1", track: 1)), Self.entry(Self.meta("s2", track: 2)),
                                         Self.entry(Self.meta("s4", track: 4))], playlists: [], records: records)
        let page = try #require(c.albumPage(id: "al1"))
        #expect(page.album.songs?.map(\.id) == ["s1", "s2", "s4"], "only what's on the phone, in the server's order")
        #expect(page.onPhone == 3 && page.total == 5)
        #expect(page.album.name == "Recorded name" && page.album.year == 1999 && page.album.coverArtId == "al-al1")
        #expect(c.albumPage(id: "nope") == nil)
        // Without a record the count comes from the album download's snapshot, else it's unknown.
        var counted = Self.meta("t1", album: "al2")
        counted.albumSongCount = 10
        let d = OfflineCatalog(entries: [Self.entry(counted), Self.entry(Self.meta("u1", album: "al3"))], playlists: [])
        #expect(d.albumPage(id: "al2")?.total == 10)
        #expect(d.albumPage(id: "al3")?.total == nil && d.albumPage(id: "al3")?.onPhone == 1)
    }

    @Test func catalog_compilationUnderItsAlbumArtist() throws {
        var records = OfflineRecords()
        let songs = [Self.song("s1", artist: "Ann", artistId: "a-ann"), Self.song("s2", artist: "Bob", artistId: "a-bob")]
        records.albums["al1"] = .init(album: Album(id: "al1", name: "Hits", artist: "Various Artists", artistId: "va",
                                                   songCount: 2, duration: 120), songs: songs, savedAt: .now)
        let entries = [Self.entry(Self.meta("s1", artist: "Ann", artistId: "a-ann", track: 1)),
                       Self.entry(Self.meta("s2", artist: "Bob", artistId: "a-bob", track: 2))]
        let c = OfflineCatalog(entries: entries, playlists: [], records: records)
        #expect(c.albums().first?.artist == "Various Artists" && c.albums().first?.artistId == "va")
        #expect(c.albumPage(id: "al1")?.compilation == true)
        #expect(Set(c.artists().map(\.id)) == ["va", "a-ann", "a-bob"], "album artists and track artists")
        // Without a record, the songs' own album artist (from an earlier page read) groups them.
        let snapshots = [Self.entry(Self.meta("s1", artist: "Ann", artistId: "a-ann", albumArtist: "Various Artists", albumArtistId: "va")),
                         Self.entry(Self.meta("s2", artist: "Bob", artistId: "a-bob", albumArtist: "Various Artists", albumArtistId: "va"))]
        let d = OfflineCatalog(entries: snapshots, playlists: [])
        #expect(d.albums().first?.artist == "Various Artists")
        #expect(d.artistPage(id: "va")?.albums.map(\.id) == ["al1"])
    }

    @Test func catalog_albumArtistPageOpensOffline() throws {
        // Library › Artists lists album artists: one no downloaded song carries as its track artist still opens.
        let entries = [Self.entry(Self.meta("s1", artist: "Ann feat. Cy", artistId: "a-ann-cy", albumArtist: "Ann", albumArtistId: "a-ann"))]
        var records = OfflineRecords()
        records.artists["a-ann"] = .init(artist: Artist(id: "a-ann", name: "Ann", albumCount: 4, coverArtId: "ar-ann"),
                                         albums: [Album(id: "al0", name: "Z", artist: "Ann", songCount: 1, duration: 1),
                                                  Album(id: "al1", name: "Album", artist: "Ann", songCount: 1, duration: 1)],
                                         savedAt: .now)
        let c = OfflineCatalog(entries: entries, playlists: [], records: records)
        let page = try #require(c.artistPage(id: "a-ann"))
        #expect(page.artist.name == "Ann" && page.artist.coverArtId == "ar-ann")
        #expect(page.albums.map(\.id) == ["al1"], "only albums with a song on the phone")
        #expect(page.songs.isEmpty)
        #expect(OfflineCatalog(entries: entries, playlists: []).artistPage(id: "a-ann") != nil, "without the record too")
    }

    @Test func catalog_featuredSongOnTheTrackArtistPage() throws {
        let entries = [Self.entry(Self.meta("s1", artist: "Cy", artistId: "a-cy", albumArtist: "Ann", albumArtistId: "a-ann")),
                       Self.entry(Self.meta("s2", album: "al2", artist: "Cy", artistId: "a-cy", albumArtist: "Cy", albumArtistId: "a-cy"))]
        let c = OfflineCatalog(entries: entries, playlists: [])
        let page = try #require(c.artistPage(id: "a-cy"))
        #expect(page.albums.map(\.id) == ["al2"], "albums where they're the album artist")
        #expect(page.songs.map(\.id) == ["s1"], "Songs on this phone: only the track artist")
        #expect(c.albums(byArtist: "a-cy").map(\.id).sorted() == ["al1", "al2"], "the existing method keeps its rule")
    }

    @Test func catalog_partlyDownloadedPlaylistKeepsItsOrder() throws {
        let downloaded = DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: "pl-1", songIds: ["s3", "s9", "s1"], savedAt: .now)
        var records = OfflineRecords()
        records.playlists["p2"] = OfflineRecords.playlistRecord(Playlist(id: "p2", name: "a recorded one", songCount: 3, duration: 1),
                                                               songs: ["s2", "s8", "s1"].map { Self.song($0) },
                                                               kind: .playlist, savedAt: .now)
        records.playlists["f1"] = OfflineRecords.playlistRecord(Playlist(id: "f1", name: "A flow", songCount: 1, duration: 1),
                                                               songs: [Self.song("s1")], kind: .flow, savedAt: .now)
        records.playlists["none"] = OfflineRecords.playlistRecord(Playlist(id: "none", name: "Nothing here", songCount: 1, duration: 1),
                                                                 songs: [Self.song("x")], kind: .playlist, savedAt: .now)
        let c = OfflineCatalog(entries: ["s1", "s2", "s3"].map { Self.entry(Self.meta($0)) }, playlists: [downloaded],
                               records: records)
        let page = try #require(c.playlistPage(id: "p1"))
        #expect(page.songs.map(\.id) == ["s3", "s1"] && page.onPhone == 2 && page.total == 3)
        let recorded = try #require(c.playlistPage(id: "p2"))
        #expect(recorded.songs.map(\.id) == ["s2", "s1"] && recorded.kind == .playlist && recorded.total == 3)
        #expect(c.playlists(includingRecorded: true).map(\.id) == ["p2", "p1"], "one A to Z list, flows kept out (D185)")
        #expect(c.playlists(includingRecorded: false).map(\.id) == ["p1"])
        #expect(c.playlists().map(\.id) == ["p1"], "the existing list is unchanged")
        #expect(c.playlistPage(id: "none") == nil)
    }

    @Test func catalog_othersPlaylistKeepsItsOwner() throws {
        var records = OfflineRecords()
        records.playlists["p1"] = OfflineRecords.playlistRecord(Playlist(id: "p1", name: "Sam's", songCount: 1, duration: 1, owner: "sam"),
                                                               songs: [Self.song("s1")], kind: .playlist, savedAt: .now)
        let c = OfflineCatalog(entries: [Self.entry(Self.meta("s1"))], playlists: [], records: records)
        #expect(c.playlistPage(id: "p1")?.playlist.owner == "sam")
        #expect(c.playlists(includingRecorded: true).first?.owner == "sam")
        // A downloaded playlist read again online carries its owner too (the newer copy wins).
        let downloaded = DownloadedPlaylist(id: "p1", name: "Old name", coverArtId: nil, songIds: ["s1"],
                                            savedAt: .distantPast)
        let d = OfflineCatalog(entries: [Self.entry(Self.meta("s1"))], playlists: [downloaded], records: records)
        #expect(d.playlistPage(id: "p1")?.playlist.name == "Sam's" && d.playlistPage(id: "p1")?.playlist.owner == "sam")
        #expect(d.playlists(includingRecorded: true).count == 1)
    }

    @Test func catalog_songGoneFromServerStaysOnPhone() throws {
        // D55: the server's album no longer lists s2, but the phone still has it, so the page still lists it.
        var records = OfflineRecords()
        records.albums["al1"] = .init(album: Album(id: "al1", name: "Album", artist: "Band", songCount: 1, duration: 60),
                                      songs: [Self.song("s1")], savedAt: .now)
        let c = OfflineCatalog(entries: [Self.entry(Self.meta("s1", track: 1)), Self.entry(Self.meta("s2", track: 2))],
                               playlists: [], records: records)
        #expect(c.albumPage(id: "al1")?.album.songs?.map(\.id) == ["s1", "s2"])
        #expect(c.songs().map(\.id) == ["s1", "s2"])
    }

    @Test func catalog_withoutRecordsFallsBackToSnapshots() throws {
        let entries = [Self.entry(Self.meta("s2", artist: "Ann", artistId: "a-ann", track: 2)),
                       Self.entry(Self.meta("s1", artist: "Bob", artistId: "a-bob", track: 1))]
        let c = OfflineCatalog(entries: entries, playlists: [])
        let page = try #require(c.albumPage(id: "al1"))
        #expect(page.album.artist == "Bob", "today's rule: the first track's artist")
        #expect(page.album.songs?.map(\.id) == ["s1", "s2"], "disc and track order")
        #expect(page.compilation == false)
        #expect(c.album(id: "al1")?.artist == "Bob")
    }

    @Test func catalog_cachedSongsNeverListed() throws {
        var records = OfflineRecords()
        records.albums["al1"] = .init(album: Album(id: "al1", name: "Album", artist: "Band", songCount: 2, duration: 1),
                                      songs: [Self.song("s1"), Self.song("c1")], savedAt: .now)
        records.playlists["p1"] = OfflineRecords.playlistRecord(Playlist(id: "p1", name: "Mix", songCount: 1, duration: 1),
                                                               songs: [Self.song("c1")], kind: .playlist, savedAt: .now)
        let c = OfflineCatalog(entries: [Self.entry(Self.meta("s1")), Self.entry(Self.meta("c1"), kind: .cache),
                                         Self.entry(Self.meta("c2", album: "al9", artistId: "a-9"), kind: .cache)],
                               playlists: [], records: records)
        #expect(c.albumPage(id: "al1")?.album.songs?.map(\.id) == ["s1"])
        #expect(c.albumPage(id: "al9") == nil && c.artistPage(id: "a-9") == nil)
        #expect(c.playlistPage(id: "p1") == nil && c.playlists(includingRecorded: true).isEmpty)
        #expect(c.song(id: "c1") == nil && c.song(id: "s1")?.title == "Ts1")
    }
}
