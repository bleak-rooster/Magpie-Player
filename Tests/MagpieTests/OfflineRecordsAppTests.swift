import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import os
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt-o2","subsonicToken":"tok-o2","token":"jwt-o2","username":"jordan"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lyricsJSON = Data(#"""
{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[{"lang":"eng","synced":true,"line":[{"start":1000,"value":"Kept on the phone"}]}]}}}
"""#.utf8)
private let extensionsJSON = Data(#"""
{"subsonic-response":{"status":"ok","version":"1.16.1","openSubsonicExtensions":[{"name":"songLyrics","versions":[1]}]}}
"""#.utf8)

/// Round 28 O2 (owner, 2026-11-15, item 1: "anything that is downloaded should be cached and only updated when in
/// online mode"): page records, refreshed song details, covers and lyrics for what's on the phone, written only online
/// and only for downloads, private at rest, erased at sign-out (D331–D336).
@MainActor @Suite(.serialized) final class OfflineRecordsAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineRecordsAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "OfflineRecordsAppTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    let fetcher = FakeFetcher()
    let covers: CoverGateFetcher
    let network = FakeNetwork(.wifi)

    init() {
        covers = CoverGateFetcher(inner: fetcher)
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2", body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}"#.utf8))
        transport.inner.stub(pathSuffix: "/rest/getOpenSubsonicExtensions", body: extensionsJSON)
        transport.inner.stub(pathSuffix: "/rest/getLyricsBySongId", body: lyricsJSON)
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                 matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                 network: network, audioFetcher: covers)
    }

    func signedIn() async throws -> AppModel {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "jordan", password: "pw-o2")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        return model
    }

    static func song(_ id: String, album: String = "al1", artist: String = "Ann", artistId: String = "ar-ann",
                     title: String? = nil) -> Song {
        Song(id: id, title: title ?? "T\(id)", artist: artist, artistId: artistId, album: "Album \(album)", albumId: album,
             duration: 200, coverArtId: "mf-\(id)")
    }

    static func album(_ id: String = "al1", count: Int = 3) -> Album {
        Album(id: id, name: "Album \(id)", artist: "Various", artistId: "va", year: 2004, songCount: count, duration: 600,
              coverArtId: "al-\(id)")
    }

    func download(_ model: AppModel, _ songs: [Song], reason: DownloadReason = .song, coverArtId: String? = nil) async {
        model.download(songs, reason: reason, coverArtId: coverArtId)
        await model.downloads!.settled()
    }

    /// Automatic offline, the one place these tests enter it (O1 may move this to its own API at merge).
    func goAutomaticOffline(_ model: AppModel) { model.serverReachable = false }
    func comeBackOnline(_ model: AppModel) { model.serverReachable = true }

    func records(_ model: AppModel) async -> OfflineRecords { await model.downloads!.store.records() }

    var recordsFile: URL? {
        let audio = tmp.appending(path: "Magpie/Audio")
        guard let scope = try? FileManager.default.contentsOfDirectory(atPath: audio.path).first else { return nil }
        return audio.appending(path: scope).appending(path: "records.json")
    }

    // MARK: - Written online only, only for downloads

    @Test func records_writtenOnlyOnline() async throws {
        let model = try await signedIn()
        let songs = (1...3).map { Self.song("s\($0)") }
        await download(model, [songs[0]])
        model.updatePreferences { $0.downloads.offlineMode = .on }   // manual offline
        await model.recordAlbumPage(Self.album(), songs: songs, into: model.downloads)
        #expect(await records(model).isEmpty, "manual offline: nothing written")
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        goAutomaticOffline(model)
        #expect(model.isOffline)
        await model.recordAlbumPage(Self.album(), songs: songs, into: model.downloads)
        await model.recordArtistPage(Artist(id: "va", name: "Various", albumCount: 1), albums: [Self.album()], into: model.downloads)
        #expect(await records(model).isEmpty, "automatic offline: nothing written")
        comeBackOnline(model)
        #expect(!model.isOffline)
        await model.recordAlbumPage(Self.album(), songs: songs, into: model.downloads)
        #expect(await records(model).albums["al1"]?.songIds == ["s1", "s2", "s3"])
    }

    @Test func records_onlyForPagesWithADownload() async throws {
        let model = try await signedIn()
        await model.recordAlbumPage(Self.album(), songs: (1...3).map { Self.song("s\($0)") }, into: model.downloads)
        await model.recordPlaylistPage(Playlist(id: "p1", name: "Mix", songCount: 1, duration: 1), songs: [Self.song("s1")],
                                       kind: .playlist, into: model.downloads)
        #expect(await records(model).isEmpty)
        #expect(recordsFile.map { FileManager.default.fileExists(atPath: $0.path) } != true)
    }

    /// A download started from a page records that page once its first song lands.
    @Test func records_writtenWhenADownloadStartsFromAPage() async throws {
        let model = try await signedIn()
        let songs = (1...2).map { Self.song("s\($0)") }
        let album = Self.album(count: 2)
        model.download(songs, reason: .album("al1"), coverArtId: album.coverArtId)
        await model.recordAlbumPage(album, songs: songs, into: model.downloads)
        await model.downloads!.settled()
        #expect(await eventually { await self.records(model).albums["al1"]?.artist == "Various" })
        let catalog = await model.offlineCatalog
        #expect(catalog.albums().first?.artist == "Various", "grouped under its album artist")
        #expect(catalog.albumPage(id: "al1")?.total == 2)
    }

    /// An artist's "Download all songs" started from their page records the page once a song lands.
    @Test func records_artistWrittenWhenTheirDownloadStartsFromThePage() async throws {
        let model = try await signedIn()
        let songs = (1...2).map { Self.song("s\($0)", artistId: "va") }
        model.download(songs, reason: .artist("va"), coverArtId: "al-al1")
        await model.recordArtistPage(Artist(id: "va", name: "Various", albumCount: 1), albums: [Self.album()], into: model.downloads)
        await model.downloads!.settled()
        #expect(await eventually { await self.records(model).artists["va"]?.albumIds == ["al1"] })
    }

    /// Q3: a playlist not downloaded but holding a download is recorded and listed offline with only that song.
    @Test func records_playlistHoldingADownloadListedOffline() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s2")])
        let mix = Playlist(id: "p1", name: "Sam's mix", songCount: 3, duration: 600, owner: "sam")
        await model.recordPlaylistPage(mix, songs: ["s1", "s2", "s3"].map { Self.song($0) }, kind: .playlist, into: model.downloads)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let catalog = await model.offlineCatalog
        #expect(catalog.playlists(includingRecorded: true).map(\.name) == ["Sam's mix"])
        let page = try #require(catalog.playlistPage(id: "p1"))
        #expect(page.songs.map(\.id) == ["s2"] && page.total == 3 && page.playlist.owner == "sam")
    }

    @Test func records_erasedAtSignOut() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1")])
        await model.recordAlbumPage(Self.album(), songs: [Self.song("s1")], into: model.downloads)
        let file = try #require(recordsFile)
        #expect(FileManager.default.fileExists(atPath: file.path))
        model.signOut()
        await model.downloadsTeardown?.value
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Fix round 2

    /// SN3: Find lyrics online switched off while LRCLIB is being asked: nothing found online is written to the phone.
    @Test func lyrics_switchedOffMidLookupWritesNoOnlineFile() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1")])
        let lrclib = GatedLrcLib()
        model.lyricsKeeper.lrclib = LrcLib(transport: lrclib, userAgent: LrcLib.userAgent(version: AppModel.marketingVersion))
        model.lyricsKeeper.findOnline = true
        let lookup = Task { await model.onlineLyrics(Self.song("s1")) }
        #expect(await eventually { lrclib.asked })
        model.lyricsKeeper.findOnline = false
        lrclib.gate.open()
        let shown = await lookup.value
        await model.downloads!.settled()
        #expect(shown == nil, "nothing shown once the switch is off")
        #expect(await model.downloads!.store.savedLyrics(songId: "s1") == nil, "nothing found online kept")
        // And `keepLyricsOnPhone` refuses lyrics found online while the switch is off.
        model.keepLyricsOnPhone("s1", .lines(Lyrics(synced: false, lines: [LyricLine(text: "x")]), .online))
        await model.downloads!.settled()
        #expect(await model.downloads!.store.savedLyrics(songId: "s1") == nil)
    }

    /// SN5: the playlist page captures the downloads before its read: a read that answers after a switch to sam (who
    /// has the same playlist downloaded) changes nothing of sam's.
    @Test func playlist_readCapturedBeforeTheReadNeverChangesAnotherAccount() async throws {
        transport.inner.stub(pathSuffix: "/rest/getPlaylist", body: Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","playlist":{"id":"p1","name":"Mix","owner":"jordan","songCount":1,"entry":[{"id":"s1","title":"Ts1","artist":"Ann","album":"A","duration":200}]}}}
        """#.utf8))
        let model = try await signedIn()
        let songs = [Self.song("s1"), Self.song("s2")]
        let mix = DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: nil, songIds: ["s1", "s2"], savedAt: .now)
        model.download(songs, reason: .playlist("p1"), playlist: mix)
        await model.downloads!.settled()
        let gate = D1Gate()
        let held = OSAllocatedUnfairLock(initialState: false)
        transport.setHook { request in
            if request.url?.path.hasSuffix("/rest/getPlaylist") == true { held.withLock { $0 = true }; await gate.wait() }
        }
        let read = Task { try await model.readPlaylistPage(id: "p1") }
        #expect(await eventually { held.withLock { $0 } })
        model.signOut()
        await model.downloadsTeardown?.value
        try await model.signIn(urls: [home], username: "sam", password: "pw-o2")
        await model.downloads!.settled()
        model.download(songs, reason: .playlist("p1"), playlist: mix)
        await model.downloads!.settled()
        gate.open()
        _ = try? await read.value
        await model.downloads!.settled()
        transport.setHook(nil)
        #expect(model.downloads!.localFiles.keys.sorted() == ["s1", "s2"], "sam's copy is untouched")
        #expect(await model.downloads!.store.playlists().first?.songIds == ["s1", "s2"])
    }

    /// SN6: a cover still being fetched when Remove all runs is never saved afterwards; L2: nothing is left in flight.
    @Test func covers_removeAllDropsAnInFlightCover() async throws {
        let model = try await signedIn()
        covers.hold()
        model.download([Self.song("s1")], reason: .song)
        #expect(await eventually { self.covers.outstanding == 1 })
        #expect(model.downloads!.coversInFlight.contains("mf-s1"))
        await model.removeAllDownloads()
        #expect(model.downloads!.coversInFlight.isEmpty, "security L2: cleared with the queues")
        covers.release()
        await model.downloads!.settled()
        #expect(await model.downloads!.store.coverURL(coverArtId: "mf-s1") == nil, "the late cover isn't saved")
    }

    /// SN6: a playlist with 200 covers never has more than 4 cover fetches out at once.
    @Test func covers_atMostFourAtOnce() async throws {
        let model = try await signedIn()
        covers.hold()
        let songs = (0..<200).map { Self.song("c\($0)") }
        let snapshot = DownloadedPlaylist(id: "p1", name: "Big", coverArtId: nil, songIds: songs.map(\.id), savedAt: .now)
        model.download(songs, reason: .playlist("p1"), playlist: snapshot)
        #expect(await eventually { self.covers.outstanding == 4 })
        covers.release()
        await model.downloads!.settled()
        #expect(covers.peak <= 4, "peak \(covers.peak)")
        #expect(covers.fetched == 200)
    }

    /// Task M1 (re-review): a parked record is never written when Magpie went offline before its song landed.
    @Test func records_parkedRecordNotWrittenWhenOfflineBeforeItLands() async throws {
        let model = try await signedIn()
        let gate = StoreGate(["s1"])
        model.downloads!.beforeStoreForTesting = { await gate.pass($0) }
        model.download([Self.song("s1")], reason: .album("al1"), coverArtId: "al-al1")
        await model.recordAlbumPage(Self.album(count: 1), songs: [Self.song("s1")], into: model.downloads)
        #expect(await eventually { gate.isWaiting("s1") })
        #expect(model.downloads!.parkedRecords.count == 1)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        gate.release("s1")
        await model.downloads!.settled()
        #expect(model.downloads!.localFiles["s1"] != nil, "the song landed")
        #expect(await records(model).isEmpty, "but nothing was recorded offline")
    }

    // MARK: - Fix round 1

    /// Security M3: a page read under one account never lands in another's records, even when it answers after the
    /// switch (the caller captures the downloads before the read).
    @Test func records_readUnderOneAccountNeverLandsInAnother() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1")])
        let jordans = model.downloads
        model.signOut()
        await model.downloadsTeardown?.value
        try await model.signIn(urls: [home], username: "sam", password: "pw-o2")
        await model.downloads!.settled()
        await download(model, [Self.song("s1")])
        await model.recordAlbumPage(Self.album(), songs: [Self.song("s1")], into: jordans)
        await model.recordPlaylistPage(Playlist(id: "p1", name: "Mix", songCount: 1, duration: 1), songs: [Self.song("s1")],
                                       kind: .playlist, into: jordans)
        #expect(await records(model).isEmpty, "jordan's read never lands in sam's records")
        await model.recordAlbumPage(Self.album(), songs: [Self.song("s1")], into: model.downloads)
        #expect(await records(model).albums["al1"] != nil, "sam's own read does")
    }

    /// Task M4: the same user on another server starts with nothing of the first server's.
    @Test func records_sameUserOnAnotherServerStartsEmpty() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1")])
        await model.recordAlbumPage(Self.album(), songs: [Self.song("s1")], into: model.downloads)
        #expect(await records(model).albums["al1"] != nil)
        let first = model.downloads!.store.directory
        try await model.signIn(urls: [URL(string: "http://nas.local:4533")!], username: "jordan", password: "pw-o2")
        await model.downloads!.settled()
        #expect(await records(model).isEmpty)
        #expect(await model.offlineCatalog.albums().isEmpty)
        #expect(model.downloads!.store.directory != first, "another server is another folder")
        #expect(!FileManager.default.fileExists(atPath: first.path), "the other server's folder went")
    }

    /// Task I1: a recorded album's cover is saved for offline; a song whose cover changed gets the new one.
    @Test func covers_recordedAlbumCoverSavedForOffline() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1")])
        var album = Self.album()
        album.coverArtId = "al-x"
        var renamed = Self.song("s1")
        renamed.coverArtId = "mf-s1-new"
        await model.recordAlbumPage(album, songs: [renamed], into: model.downloads)
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let cover = try #require(model.localCoverURL("al-x"))
        #expect(FileManager.default.fileExists(atPath: cover.path), "the album's cover is on the phone")
        #expect(await model.offlineCatalog.albums().first?.coverArtId == "al-x")
        let songCover = try #require(model.localCoverURL("mf-s1-new"))
        #expect(FileManager.default.fileExists(atPath: songCover.path), "the song's new cover too")
    }

    /// Task I2: a downloaded playlist saves each of its songs' covers, under the downloads' mobile-data rule.
    @Test func covers_savedForEachSongOfADownloadedPlaylist() async throws {
        let model = try await signedIn()
        network.status = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)
        let songs = [Self.song("s1"), Self.song("s2"), Self.song("s3", album: "al2")]
        let snapshot = DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: "pl-1", songIds: songs.map(\.id), savedAt: .now)
        model.download(songs, reason: .playlist("p1"), playlist: snapshot, coverArtId: "pl-1")
        await model.downloads!.settled()
        #expect(fetcher.urls.filter { $0.path.hasSuffix("/rest/getCoverArt") }.isEmpty, "mobile data not allowed: nothing yet")
        network.status = .wifi
        let store = model.downloads!.store
        #expect(await eventually {
            await model.downloads!.settled()
            for id in ["mf-s1", "mf-s2", "mf-s3", "pl-1"] where await store.coverURL(coverArtId: id) == nil { return false }
            return true
        })
        #expect(coverFetches("mf-s1") == 1)
    }

    /// Security L1: a "cover" over 5 MB is refused before it is read.
    @Test func covers_oversizeImageRefused() async throws {
        let model = try await signedIn()
        fetcher.bytes = 6 * 1024 * 1024
        await download(model, [Self.song("s1")])
        #expect(coverFetches("mf-s1") == 1)
        #expect(await model.downloads!.store.coverURL(coverArtId: "mf-s1") == nil)
    }

    /// Security L4 (D336 amended): turning Find lyrics online off removes the lyrics found online kept on the phone.
    @Test func lyrics_foundOnlineGoWhenFindLyricsOnlineTurnsOff() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1"), Self.song("s2")])
        let store = model.downloads!.store
        let lines = Lyrics(synced: false, lines: [LyricLine(text: "la")])
        try await store.saveLyrics(OfflineLyrics(songId: "s1", source: .online, lyrics: lines, savedAt: .now))
        try await store.saveLyrics(OfflineLyrics(songId: "s2", source: .library, lyrics: lines, savedAt: .now))
        model.lyricsKeeper.findOnline = true
        model.lyricsKeeper.findOnline = false
        await model.downloads!.settled()
        #expect(await store.savedLyrics(songId: "s1") == nil)
        #expect(await store.savedLyrics(songId: "s2") != nil, "the library's stay")
    }


    // MARK: - Privacy at rest

    @Test func records_noURLsTokensOrAddresses() async throws {
        let model = try await signedIn()
        let song = Self.song("s1")
        await download(model, [song], reason: .album("al1"), coverArtId: "al-al1")
        await model.recordAlbumPage(Self.album(), songs: [song], into: model.downloads)
        await model.recordArtistPage(Artist(id: "va", name: "Various", albumCount: 1, coverArtId: "ar-va"), albums: [Self.album()], into: model.downloads)
        await model.recordPlaylistPage(Playlist(id: "p1", name: "Mix", songCount: 1, duration: 1, owner: "jordan", changed: .now),
                                       songs: [song], kind: .playlist, into: model.downloads)
        _ = try await model.lyricsForPane(song)
        let scope = try #require(recordsFile).deletingLastPathComponent()
        #expect(await eventually { FileManager.default.fileExists(atPath: scope.appending(path: "lyrics").path) })
        var files = [scope.appending(path: "records.json")]
        for folder in ["lyrics", "playlists"] {
            let dir = scope.appending(path: folder)
            files += ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { dir.appending(path: $0) }
        }
        #expect(files.count >= 2)
        for url in files {
            let text = try String(decoding: Data(contentsOf: url), as: UTF8.self).lowercased()
            for needle in ["http", "u=", "t=", "s=", "jwt", "token", "salt", "tok-o2", "pw-o2", "192.168.1.2", "rest/"] {
                #expect(!text.contains(needle), "\(url.lastPathComponent) holds \(needle)")
            }
        }
    }

    // MARK: - Song details (D332)

    @Test func catalog_metadataRefreshedOnlineOnly() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", title: "Old name")])
        model.updatePreferences { $0.downloads.offlineMode = .on }
        await model.recordAlbumPage(Self.album(), songs: [Self.song("s1", title: "Offline name")], into: model.downloads)
        #expect(await model.offlineCatalog.songs().map(\.title) == ["Old name"], "never offline")
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually { !model.isOffline })   // Round 28 O1 fix round 1 (design H1): online once the check answers
        await model.recordAlbumPage(Self.album(), songs: [Self.song("s1", title: "New name")], into: model.downloads)
        let catalog = await model.offlineCatalog
        #expect(catalog.songs().map(\.title) == ["New name"])
        #expect(catalog.albums().first?.artist == "Various")
    }

    /// D55: a song gone from the server stays on the phone; online its page simply doesn't list it, Downloads still does.
    @Test func catalog_songGoneFromServerStaysOnPhone() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1"), Self.song("s2")], reason: .album("al1"), coverArtId: "al-al1")
        await model.recordAlbumPage(Self.album(count: 1), songs: [Self.song("s1")], into: model.downloads)
        let catalog = await model.offlineCatalog
        #expect(catalog.songs().map(\.id) == ["s1", "s2"])
        #expect(catalog.albumPage(id: "al1")?.album.songs?.map(\.id) == ["s1", "s2"])
    }

    // MARK: - Covers (D334)

    func coverFetches(_ id: String) -> Int {
        fetcher.urls.filter { $0.path.hasSuffix("/rest/getCoverArt") && $0.query?.contains("id=\(id)") == true }.count
    }

    @Test func covers_savedForASingleSongDownload() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1")])
        #expect(await eventually { await model.downloads!.store.coverURL(coverArtId: "mf-s1") != nil })
        #expect(coverFetches("mf-s1") == 1)
    }

    @Test func covers_savedOncePerAlbum() async throws {
        let model = try await signedIn()
        await download(model, (1...3).map { Self.song("s\($0)") }, reason: .album("al1"), coverArtId: "al-al1")
        #expect(coverFetches("al-al1") == 1)
        #expect(coverFetches("mf-s1") == 0, "an album's songs show its cover")
        await model.recordArtistPage(Artist(id: "va", name: "Various", albumCount: 1, coverArtId: "ar-va"), albums: [Self.album()], into: model.downloads)
        await model.downloads!.settled()
        #expect(await eventually { await model.downloads!.store.coverURL(coverArtId: "ar-va") != nil })
        #expect(fetcher.urls.contains { $0.query?.contains("id=ar-va") == true && $0.query?.contains("size=300") == true },
                "a recorded artist's picture at 300 px")
    }

    @Test func covers_prunedWhenUnreferenced() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1")])
        let store = model.downloads!.store
        #expect(await eventually { await store.coverURL(coverArtId: "mf-s1") != nil })
        await model.removeSongDownload("s1")
        #expect(await store.coverURL(coverArtId: "mf-s1") == nil)
    }

    @Test func covers_neverFetchedOffline() async throws {
        let model = try await signedIn()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.download([Self.song("s1")], reason: .song)
        await model.downloads!.settled()
        await model.recordArtistPage(Artist(id: "ar-ann", name: "Ann", albumCount: 1, coverArtId: "ar-ann"), albums: [], into: model.downloads)
        await model.downloads!.settled()
        #expect(fetcher.urls.filter { $0.path.hasSuffix("/rest/getCoverArt") }.isEmpty)
    }

    // MARK: - Lyrics (D336)

    @Test func lyrics_keptForDownloadedSongsOnly() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1")])
        _ = try await model.lyricsForPane(Self.song("s1"))
        _ = try await model.lyricsForPane(Self.song("s2"))
        let store = model.downloads!.store
        await model.downloads!.settled()   // fix round 1 (security L5): the save is tracked by the manager
        #expect(await store.savedLyrics(songId: "s1") != nil)
        #expect(await store.savedLyrics(songId: "s2") == nil, "not a download: memory only, as before")
        await model.removeSongDownload("s1")
        #expect(await store.savedLyrics(songId: "s1") == nil, "lyrics go with the song")
    }

    @Test func lyrics_readOfflineAfterRelaunch() async throws {
        let first = try await signedIn()
        await download(first, [Self.song("s1")])
        _ = try await first.lyricsForPane(Self.song("s1"))
        #expect(await eventually { await first.downloads!.store.savedLyrics(songId: "s1") != nil })
        let model = makeModel()
        model.resumeSavedSession()
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let shown = try await model.lyricsForPane(Self.song("s1"))
        guard case .lines(let lyrics, let source)? = shown else { Issue.record("no kept lyrics offline"); return }
        #expect(lyrics.lines.map(\.text) == ["Kept on the phone"] && source == .library)
        #expect(await model.savedLyrics(songId: "s1") == shown)
    }
}

/// Round 28 O2 fix round 2: LRCLIB on a gate (never the real host): answers plain lyrics once the test opens it.
final class GatedLrcLib: HTTPTransport, @unchecked Sendable {
    let gate = D1Gate()
    private let state = OSAllocatedUnfairLock(initialState: false)
    var asked: Bool { state.withLock { $0 } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withLock { $0 = true }
        await gate.wait()
        let body = Data(#"{"id":1,"plainLyrics":"Found online","syncedLyrics":null,"instrumental":false}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!)
    }
}

/// Round 28 O2 fix round 2: audio through `FakeFetcher`; covers counted (outstanding, peak, fetched) and, while held,
/// waiting until released.
final class CoverGateFetcher: AudioFetching, @unchecked Sendable {
    let inner: FakeFetcher
    private struct State { var held = false; var outstanding = 0; var peak = 0; var fetched = 0; var gate: D1Gate? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(inner: FakeFetcher) { self.inner = inner }
    var outstanding: Int { state.withLock { $0.outstanding } }
    var peak: Int { state.withLock { $0.peak } }
    var fetched: Int { state.withLock { $0.fetched } }
    func hold() { state.withLock { $0.gate = D1Gate() } }
    func release() { state.withLock { s in s.gate?.open(); s.gate = nil } }
    func fetch(_ url: URL, allowsCellular: Bool) async throws -> (file: URL, mimeType: String?) {
        guard url.path.hasSuffix("/rest/getCoverArt") else { return try await inner.fetch(url, allowsCellular: allowsCellular) }
        let gate = state.withLock { s -> D1Gate? in
            s.outstanding += 1
            s.peak = max(s.peak, s.outstanding)
            return s.gate
        }
        defer { state.withLock { $0.outstanding -= 1; $0.fetched += 1 } }
        await gate?.wait()
        return try await inner.fetch(url, allowsCellular: allowsCellular)
    }
}
