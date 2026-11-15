import Foundation
import Synchronization
import Testing
import MagpieCore
@testable import Playback

/// Round 28 O2 (owner, 2026-11-15): offline page records in the store (D331–D334): written only for pages with a
/// download and only when different, pruned with the last download, cleared with Remove all downloads and the scope,
/// bounded, private at rest, and covers kept only while something names them.
@Suite final class OfflineRecordsTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineRecordsTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    final class Clock: Sendable {
        let current = Mutex(Date(timeIntervalSince1970: 1_000))
        func advance(_ s: TimeInterval) { current.withLock { $0 += s } }
        var now: @Sendable () -> Date { { [self] in current.withLock { $0 } } }
    }

    func tempFile() throws -> URL {
        let incoming = tmp.appending(path: "incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let url = incoming.appending(path: UUID().uuidString)
        try Data(count: 100).write(to: url)
        return url
    }

    static func song(_ id: String, album: String = "al1", artist: String = "Band", artistId: String = "ar1",
                     title: String? = nil, track: Int? = nil, cover: String? = nil) -> Song {
        Song(id: id, title: title ?? "T\(id)", artist: artist, artistId: artistId, album: "Album \(album)", albumId: album,
             track: track, duration: 100, coverArtId: cover ?? "mf-\(id)")
    }

    static func album(_ id: String = "al1", count: Int = 3, artist: String = "Band", artistId: String = "ar1") -> Album {
        Album(id: id, name: "Album \(id)", artist: artist, artistId: artistId, year: 2001, songCount: count, duration: 300,
              coverArtId: "al-\(id)")
    }

    func download(_ store: AudioStore, _ song: Song, reason: DownloadReason = .song) async throws {
        try await store.add(tempFile(), metadata: AudioMetadata(song), quality: .original, kind: .download, reason: reason,
                            fileExtension: "mp3", downloadsLimit: nil)
    }

    func cache(_ store: AudioStore, _ song: Song) async throws {
        try await store.add(tempFile(), metadata: AudioMetadata(song), quality: .original, kind: .cache, reason: nil,
                            fileExtension: "mp3", downloadsLimit: nil)
    }

    func store(_ scope: String = "abc", clock: Clock = Clock()) async -> AudioStore {
        let store = AudioStore(root: tmp, scope: scope, now: clock.now)
        await store.load()
        return store
    }

    var recordsURL: URL { tmp.appending(path: "Magpie/Audio/abc/records.json") }

    // MARK: - Only for pages with a download

    @Test func records_onlyForPagesWithADownload() async throws {
        let store = await store()
        let songs = (1...3).map { Self.song("s\($0)") }
        let record = OfflineRecords.AlbumRecord(album: Self.album(), songs: songs, savedAt: .now)
        #expect(try await store.recordAlbum(record) == .noDownload, "nothing on the phone: nothing kept")
        try await cache(store, songs[0])
        #expect(try await store.recordAlbum(record) == .noDownload, "a cached song isn't a download")
        #expect(!FileManager.default.fileExists(atPath: recordsURL.path))
        try await download(store, songs[1])
        #expect(try await store.recordAlbum(record) == .written)
        #expect(await store.records().albums["al1"]?.songIds == ["s1", "s2", "s3"])

        let artist = OfflineRecords.ArtistRecord(artist: Artist(id: "ar9", name: "Other", albumCount: 1),
                                                 albums: [Self.album("al9")], savedAt: .now)
        #expect(try await store.recordArtist(artist) == .noDownload)
        let band = OfflineRecords.ArtistRecord(artist: Artist(id: "ar1", name: "Band", albumCount: 1, coverArtId: "ar-1"),
                                               albums: [Self.album()], savedAt: .now)
        #expect(try await store.recordArtist(band) == .written)

        let mix = Playlist(id: "p1", name: "Mix", songCount: 2, duration: 200, owner: "sam")
        let other = OfflineRecords.playlistRecord(mix, songs: [Self.song("x1"), Self.song("x2")], kind: .playlist, savedAt: .now)
        #expect(try await store.recordPlaylist(other) == .noDownload)
        let holding = OfflineRecords.playlistRecord(mix, songs: [Self.song("x1"), songs[1]], kind: .playlist, savedAt: .now)
        #expect(try await store.recordPlaylist(holding) == .written)
        #expect(await store.records().playlists["p1"]?.owner == "sam")
    }

    @Test func records_writeOnlyWhenDifferent() async throws {
        let clock = Clock()
        let store = await store(clock: clock)
        let songs = (1...3).map { Self.song("s\($0)") }
        try await download(store, songs[0])
        #expect(try await store.recordAlbum(.init(album: Self.album(), songs: songs, savedAt: clock.now())) == .written)
        let written = try Data(contentsOf: recordsURL)
        clock.advance(60)
        #expect(try await store.recordAlbum(.init(album: Self.album(), songs: songs, savedAt: clock.now())) == .unchanged,
                "only when it was saved differs")
        #expect(try Data(contentsOf: recordsURL) == written, "the file isn't written again")
        var renamed = Self.album()
        renamed.name = "Renamed"
        #expect(try await store.recordAlbum(.init(album: renamed, songs: songs, savedAt: clock.now())) == .written)
        #expect(await store.records().albums["al1"]?.name == "Renamed")
    }

    // MARK: - Prune and erase

    @Test func records_prunedWhenTheLastSongLeaves() async throws {
        let store = await store()
        let songs = (1...2).map { Self.song("s\($0)") }
        try await download(store, songs[0], reason: .album("al1"))
        try await download(store, songs[1], reason: .album("al1"))
        try await store.recordAlbum(.init(album: Self.album(), songs: songs, savedAt: .now))
        try await store.recordArtist(.init(artist: Artist(id: "ar1", name: "Band", albumCount: 1), albums: [Self.album()],
                                           savedAt: .now))
        try await store.recordPlaylist(OfflineRecords.playlistRecord(Playlist(id: "p1", name: "Mix", songCount: 1, duration: 1),
                                                                     songs: [songs[1]], kind: .playlist, savedAt: .now))
        try await store.saveLyrics(OfflineLyrics(songId: "s2", source: .library,
                                                 lyrics: Lyrics(synced: false, lines: [LyricLine(text: "la")]), savedAt: .now))
        try await store.removeReason(.album("al1"), songIds: ["s2"])
        var records = await store.records()
        #expect(records.albums["al1"] != nil && records.artists["ar1"] != nil, "s1 still holds the album and its artist")
        #expect(records.playlists["p1"] == nil, "the playlist's only download left")
        #expect(await store.savedLyrics(songId: "s2") == nil, "lyrics go with the song")
        try await store.removeReason(.album("al1"))
        records = await store.records()
        #expect(records.isEmpty, "the last song left: every record went")
        let reloaded = AudioStore(root: tmp, scope: "abc")
        await reloaded.load()
        #expect(await reloaded.records().isEmpty, "and on disk")
    }

    @Test func records_clearedByRemoveAllDownloads() async throws {
        let store = await store()
        try await download(store, Self.song("s1"))
        try await store.recordAlbum(.init(album: Self.album(), songs: [Self.song("s1")], savedAt: .now))
        try await store.saveLyrics(OfflineLyrics(songId: "s1", source: .online, lyrics: nil, savedAt: .now))
        try await store.saveCover(Data([1, 2]), coverArtId: "al-al1")
        try await store.removeAll(kind: .download)
        #expect(await store.records().isEmpty)
        #expect(await store.savedLyrics(songId: "s1") == nil)
        #expect(await store.coverURL(coverArtId: "al-al1") == nil)
        #expect(!FileManager.default.fileExists(atPath: recordsURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.directory.appending(path: "lyrics").path))
    }

    @Test func records_erasedWithTheScope() async throws {
        let store = await store()
        try await download(store, Self.song("s1"))
        try await store.recordAlbum(.init(album: Self.album(), songs: [Self.song("s1")], savedAt: .now))
        try await store.saveLyrics(OfflineLyrics(songId: "s1", source: .online, lyrics: nil, savedAt: .now))
        await store.eraseScope()
        #expect(await store.records().isEmpty)
        #expect(await store.savedLyrics(songId: "s1") == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test func records_neverCrossAccounts() async throws {
        let jordan = await store("jordan1")
        let sam = await store("sam1")
        try await download(jordan, Self.song("s1"))
        try await jordan.recordAlbum(.init(album: Self.album(), songs: [Self.song("s1")], savedAt: .now))
        try await jordan.saveLyrics(OfflineLyrics(songId: "s1", source: .library,
                                                  lyrics: Lyrics(synced: false, lines: [LyricLine(text: "la")]), savedAt: .now))
        #expect(await sam.records().isEmpty)
        #expect(await sam.savedLyrics(songId: "s1") == nil)
        try await download(sam, Self.song("s1"))
        #expect(try await sam.recordArtist(.init(artist: Artist(id: "ar1", name: "Band", albumCount: 1), albums: [],
                                                 savedAt: .now)) == .written)
        #expect(await jordan.records().artists.isEmpty, "sam's records never reach jordan's scope")
        #expect(await sam.records().albums.isEmpty)
    }

    // MARK: - Bounds

    @Test func records_boundsTrimAndOversizeReadsAsNone() async throws {
        var records = OfflineRecords()
        for i in 0..<(OfflineRecords.maxPlaylists + 5) {
            let p = Playlist(id: "p\(i)", name: "P\(i)", songCount: 1, duration: 1)
            records.playlists["p\(i)"] = OfflineRecords.playlistRecord(p, songs: [Self.song("s\(i)")], kind: .playlist,
                                                                      savedAt: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        let long = (0..<(OfflineRecords.maxPlaylistSongs + 10)).map { Self.song("x\($0)") }
        records.playlists["big"] = OfflineRecords.playlistRecord(Playlist(id: "big", name: "Big", songCount: 0, duration: 0),
                                                                songs: long, kind: .playlist, savedAt: .distantFuture)
        records.albums["wrong"] = .init(album: Self.album("al1"), songs: [], savedAt: .now)
        let bounded = records.bounded()
        #expect(bounded.playlists.count == OfflineRecords.maxPlaylists)
        #expect(bounded.playlists["p0"] == nil && bounded.playlists["p5"] == nil, "the oldest go first")
        #expect(bounded.playlists["p6"] != nil)
        #expect(bounded.playlists["big"]?.songIds.count == OfflineRecords.maxPlaylistSongs)
        #expect(bounded.albums["wrong"] == nil, "a record under another id is dropped")
        #expect(OfflineRecords.AlbumRecord(album: Self.album(), songs: long, savedAt: .now).songIds.count
                == OfflineRecords.maxAlbumSongs)

        // A file over 8 MB reads as none; the store then serves no records (and today's snapshot grouping applies).
        let store = await store()
        try await download(store, Self.song("s1"))
        try await store.recordAlbum(.init(album: Self.album(), songs: [Self.song("s1")], savedAt: .now))
        var huge = Data("{\"version\":1,\"albums\":{},\"artists\":{},\"playlists\":{},\"pad\":\"".utf8)
        huge.append(Data(repeating: UInt8(ascii: "a"), count: OfflineRecords.maxBytes))
        huge.append(Data("\"}".utf8))
        try huge.write(to: recordsURL)
        let reloaded = AudioStore(root: tmp, scope: "abc")
        await reloaded.load()
        #expect(await reloaded.records().isEmpty)
        #expect(OfflineRecords.decode(huge) == nil)
        #expect(OfflineRecords.decode(Data("{\"version\":2,\"albums\":{},\"artists\":{},\"playlists\":{}}".utf8)) == nil)
        #expect(OfflineRecords.decode(Data("not json".utf8)) == nil)
        // A write over it starts afresh from the download's page.
        #expect(try await reloaded.recordAlbum(.init(album: Self.album(), songs: [Self.song("s1")], savedAt: .now)) == .written)
        #expect(try Data(contentsOf: recordsURL).count < 10_000)
    }

    // MARK: - Privacy at rest

    @Test func records_noURLsTokensOrAddresses() async throws {
        let store = await store()
        try await download(store, Self.song("s1"))
        try await store.recordAlbum(.init(album: Self.album(), songs: [Self.song("s1")], savedAt: .now))
        try await store.recordArtist(.init(artist: Artist(id: "ar1", name: "Band", albumCount: 1, coverArtId: "ar-1"),
                                           albums: [Self.album()], savedAt: .now))
        try await store.recordPlaylist(OfflineRecords.playlistRecord(
            Playlist(id: "p1", name: "Mix", songCount: 1, duration: 1, owner: "jordan", changed: .now),
            songs: [Self.song("s1")], kind: .flow, savedAt: .now))
        try await store.saveLyrics(OfflineLyrics(songId: "s1", source: .online,
                                                 lyrics: Lyrics(synced: true, lines: [LyricLine(start: 1, text: "la")]),
                                                 savedAt: .now))
        for url in [recordsURL] + lyricsFiles(store) {
            let text = try String(decoding: Data(contentsOf: url), as: UTF8.self).lowercased()
            for needle in ["http", "u=", "t=", "s=", "jwt", "token", "salt", "music.example", "nas.local", "password"] {
                #expect(!text.contains(needle), "\(url.lastPathComponent) holds \(needle)")
            }
        }
        #expect(lyricsFiles(store).count == 1)
    }

    @Test func records_excludedFromBackupAndProtected() async throws {
        let store = await store()
        try await download(store, Self.song("s1"))
        try await store.recordAlbum(.init(album: Self.album(), songs: [Self.song("s1")], savedAt: .now))
        try await store.saveLyrics(OfflineLyrics(songId: "s1", source: .library,
                                                 lyrics: Lyrics(synced: false, lines: [LyricLine(text: "la")]), savedAt: .now))
        let lyricsDirectory = store.directory.appending(path: "lyrics", directoryHint: .isDirectory)
        for url in [recordsURL, lyricsDirectory] + lyricsFiles(store) {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) is there")
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                    "\(url.lastPathComponent)")
        }
        #expect(recordsURL.path.hasPrefix(store.directory.path), "inside the account's own folder")
    }

    /// Before first unlock the records can't be read: none are served and none are written over.
    @Test func records_unreadableBeforeFirstUnlockAreNeverWrittenOver() async throws {
        let first = await store()
        try await download(first, Self.song("s1"))
        try await first.recordAlbum(.init(album: Self.album(), songs: [Self.song("s1")], savedAt: .now))
        let saved = try Data(contentsOf: recordsURL)
        let locked = Mutex(true)
        let early = AudioStore(root: tmp, scope: "abc", isProtectedDataAvailable: { !locked.withLock { $0 } },
                               read: { url in
                                   if locked.withLock({ $0 }), url.lastPathComponent == "records.json" {
                                       throw CocoaError(.fileReadNoPermission)
                                   }
                                   return try Data(contentsOf: url)
                               })
        await early.load()
        #expect(await early.records().isEmpty)
        await #expect(throws: AudioStoreError.notReady) {
            try await early.recordArtist(.init(artist: Artist(id: "ar1", name: "Band", albumCount: 1), albums: [], savedAt: .now))
        }
        #expect(try Data(contentsOf: recordsURL) == saved)
        locked.withLock { $0 = false }
        #expect(await early.records().albums["al1"] != nil, "read once it can be")
    }

    /// Fix round 1 (security M2): one oversized record is refused, never written by evicting everything else; quickly.
    @Test func records_oversizeRecordRefusedOthersKept() async throws {
        let started = ContinuousClock.now
        let store = await store()
        try await download(store, Self.song("s1"))
        try await store.recordAlbum(.init(album: Self.album(), songs: [Self.song("s1")], savedAt: .now))
        let longId = String(repeating: "x", count: OfflineRecords.maxIdBytes + 1)
        var hostile = Self.album(longId)
        hostile.name = String(repeating: "n", count: 2_000_000)
        #expect(try await store.recordAlbum(.init(album: hostile, songs: [Self.song("s1")], savedAt: .distantFuture)) == .refused,
                "an id too long to keep")
        let huge = (0..<OfflineRecords.maxPlaylistSongs).map { Self.song("s1-" + String(repeating: "\($0 % 10)", count: 200) + "\($0)") }
        await store.setRecordByteLimitForTesting(100_000)
        let big = OfflineRecords.playlistRecord(Playlist(id: "p-big", name: "Big", songCount: 1, duration: 1),
                                                songs: [Self.song("s1")] + huge, kind: .playlist, savedAt: .distantFuture)
        #expect(try await store.recordPlaylist(big) == .refused, "bigger than one record may be")
        let records = await store.records()
        #expect(records.albums.keys.sorted() == ["al1"], "the others are kept")
        #expect(records.playlists.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// Fix round 2 (SN4): ids that JSON escapes (control characters take six bytes each) still leave a file within
    /// 8 MB, which a fresh store reads back.
    @Test func records_controlCharacterIdsStayWithinTheFile() async throws {
        var records = OfflineRecords()
        let control = String(repeating: "\u{1}", count: OfflineRecords.maxIdBytes - 6)
        for i in 0..<OfflineRecords.maxAlbums {
            let id = control + String(format: "%06d", i)
            records.albums[id] = OfflineRecords.AlbumRecord(album: Album(id: id, name: "A", artist: "B", songCount: 1, duration: 1),
                                                            songs: [Self.song(control + "s\(i)")],
                                                            savedAt: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        let bounded = records.bounded()
        let size = try #require(bounded.encoded()?.count)
        #expect(size <= OfflineRecords.maxBytes, "\(size) bytes")
        #expect(!bounded.albums.isEmpty)
        let store = await store()
        try await download(store, Self.song("s1"))
        try await store.writeRecords(bounded)
        let fresh = AudioStore(root: tmp, scope: "abc")
        await fresh.load()
        #expect(await fresh.records().albums.count == bounded.albums.count, "read back, not as none")
    }

    /// Fix round 1 (security M2): text is bounded by UTF-8 bytes, cut between characters; long ids leave the lists.
    @Test func records_textBoundedByBytes() throws {
        var album = Self.album()
        album.name = String(repeating: "é", count: 400)   // 800 bytes
        album.artist = String(repeating: "👩‍👩‍👧", count: 100)
        let longSong = Self.song(String(repeating: "z", count: OfflineRecords.maxIdBytes + 1))
        let record = OfflineRecords.AlbumRecord(album: album, songs: [Self.song("s1"), longSong], savedAt: .now)
        #expect(record.name.utf8.count <= OfflineRecords.maxText && record.name.allSatisfy { $0 == "é" } && !record.name.isEmpty)
        #expect(record.artist.utf8.count <= OfflineRecords.maxText && record.artist.allSatisfy { $0 == "👩‍👩‍👧" })
        #expect(record.songIds == ["s1"], "an id too long to keep leaves the list")
        let playlist = OfflineRecords.playlistRecord(Playlist(id: "p1", name: String(repeating: "ß", count: 600), songCount: 1,
                                                              duration: 1, owner: String(repeating: "ø", count: 600)),
                                                     songs: [Self.song("s1")], kind: .playlist, savedAt: .now)
        #expect(playlist.name.utf8.count <= OfflineRecords.maxText && (playlist.owner?.utf8.count ?? 0) <= OfflineRecords.maxText)
    }

    @Test func records_oldDownloadedPlaylistFileStillReads() throws {
        let old = Data(#"{"id":"p1","name":"Mix","coverArtId":"pl-1","songIds":["s1","s2"],"savedAt":10}"#.utf8)
        let playlist = try JSONDecoder().decode(DownloadedPlaylist.self, from: old)
        #expect(playlist.songIds == ["s1", "s2"] && playlist.owner == nil && playlist.kind == nil && playlist.changed == nil)
        let later = Data(#"{"id":"p1","name":"Mix","songIds":[],"savedAt":10,"kind":"somethingNew","owner":"sam"}"#.utf8)
        let tolerant = try JSONDecoder().decode(DownloadedPlaylist.self, from: later)
        #expect(tolerant.kind == nil && tolerant.owner == "sam", "a kind from a later version reads as nil")
        let oldSidecar = Data(#"{"songId":"s1","title":"T","artist":"A","album":"B","duration":1}"#.utf8)
        let meta = try JSONDecoder().decode(AudioMetadata.self, from: oldSidecar)
        #expect(meta.albumArtist == nil && meta.albumArtistId == nil)
    }

    // MARK: - Song snapshots (D332)

    @Test func refreshMetadata_rewritesShownFieldsAndKeepsTheRest() async throws {
        let clock = Clock()
        let store = await store(clock: clock)
        var song = Self.song("s1", track: 1)
        song.bitRate = 900
        try await download(store, song, reason: .album("al1"))
        try await store.promote(songId: "s1", reason: .song, downloadsLimit: nil, albumCoverArtId: "al-al1", albumSongCount: 9)
        let before = try #require(await store.entry(songId: "s1"))
        #expect(try await store.refreshMetadata(song) == false, "nothing shown differs")
        clock.advance(100)
        var renamed = song
        renamed.title = "New title"; renamed.track = 2; renamed.bitRate = 128
        #expect(try await store.refreshMetadata(renamed, albumArtist: "Various", albumArtistId: "va") == true)
        let after = try #require(await store.entry(songId: "s1"))
        #expect(after.metadata.title == "New title" && after.metadata.track == 2)
        #expect(after.metadata.albumArtist == "Various" && after.metadata.albumArtistId == "va")
        #expect(after.metadata.albumCoverArtId == "al-al1" && after.metadata.albumSongCount == 9)
        #expect(after.metadata.bitRate == 900, "the file on the phone is still what it was")
        #expect(after.quality == before.quality && after.reasons == before.reasons)
        #expect(after.downloadedAt == before.downloadedAt && after.fileName == before.fileName)
        // A relaunch reads the new snapshot from the sidecar.
        let reloaded = AudioStore(root: tmp, scope: "abc")
        await reloaded.load()
        #expect(await reloaded.entry(songId: "s1")?.metadata.title == "New title")
        // A later page without an album artist keeps the one known.
        var again = renamed
        again.title = "Third"
        try await store.refreshMetadata(again)
        #expect(await store.entry(songId: "s1")?.metadata.albumArtistId == "va")
        // A cached song isn't a download: left alone.
        try await cache(store, Self.song("c1"))
        var cached = Self.song("c1"); cached.title = "X"
        #expect(try await store.refreshMetadata(cached) == false)
    }

    // MARK: - Covers (D334)

    @Test func covers_prunedWhenUnreferenced() async throws {
        let store = await store()
        try await download(store, Self.song("s1", cover: "mf-s1"))
        try await store.recordArtist(.init(artist: Artist(id: "ar1", name: "Band", albumCount: 1, coverArtId: "ar-1"),
                                           albums: [], savedAt: .now))
        for id in ["mf-s1", "ar-1", "al-gone", "pending"] { try await store.saveCover(Data([1]), coverArtId: id) }
        #expect(await store.pruneCovers(keeping: ["pending"]) == 1)
        #expect(await store.coverURL(coverArtId: "mf-s1") != nil, "a download's own cover")
        #expect(await store.coverURL(coverArtId: "ar-1") != nil, "a recorded artist's picture")
        #expect(await store.coverURL(coverArtId: "pending") != nil, "one the caller still needs")
        #expect(await store.coverURL(coverArtId: "al-gone") == nil)
        try await store.removeReason(.song)
        #expect(await store.pruneCovers(keeping: []) == 3, "nothing on the phone names them now")
    }

    func lyricsFiles(_ store: AudioStore) -> [URL] {
        let dir = store.directory.appending(path: "lyrics", directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { dir.appending(path: $0) }
    }
}
