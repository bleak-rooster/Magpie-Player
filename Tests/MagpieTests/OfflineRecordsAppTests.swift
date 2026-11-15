import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
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

    init() {
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
                 network: FakeNetwork(.wifi), audioFetcher: fetcher)
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
        await model.recordAlbumPage(Self.album(), songs: songs)
        #expect(await records(model).isEmpty, "manual offline: nothing written")
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        model.serverReachable = false   // automatic offline
        #expect(model.isOffline)
        await model.recordAlbumPage(Self.album(), songs: songs)
        await model.recordArtistPage(Artist(id: "va", name: "Various", albumCount: 1), albums: [Self.album()])
        #expect(await records(model).isEmpty, "automatic offline: nothing written")
        model.serverReachable = true
        #expect(!model.isOffline)
        await model.recordAlbumPage(Self.album(), songs: songs)
        #expect(await records(model).albums["al1"]?.songIds == ["s1", "s2", "s3"])
    }

    @Test func records_onlyForPagesWithADownload() async throws {
        let model = try await signedIn()
        await model.recordAlbumPage(Self.album(), songs: (1...3).map { Self.song("s\($0)") })
        await model.recordPlaylistPage(Playlist(id: "p1", name: "Mix", songCount: 1, duration: 1), songs: [Self.song("s1")],
                                       kind: .playlist)
        #expect(await records(model).isEmpty)
        #expect(recordsFile.map { FileManager.default.fileExists(atPath: $0.path) } != true)
    }

    /// A download started from a page records that page once its first song lands.
    @Test func records_writtenWhenADownloadStartsFromAPage() async throws {
        let model = try await signedIn()
        let songs = (1...2).map { Self.song("s\($0)") }
        let album = Self.album(count: 2)
        model.download(songs, reason: .album("al1"), coverArtId: album.coverArtId)
        await model.recordAlbumPage(album, songs: songs)
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
        await model.recordArtistPage(Artist(id: "va", name: "Various", albumCount: 1), albums: [Self.album()])
        await model.downloads!.settled()
        #expect(await eventually { await self.records(model).artists["va"]?.albumIds == ["al1"] })
    }

    /// Q3: a playlist not downloaded but holding a download is recorded and listed offline with only that song.
    @Test func records_playlistHoldingADownloadListedOffline() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s2")])
        let mix = Playlist(id: "p1", name: "Sam's mix", songCount: 3, duration: 600, owner: "sam")
        await model.recordPlaylistPage(mix, songs: ["s1", "s2", "s3"].map { Self.song($0) }, kind: .playlist)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let catalog = await model.offlineCatalog
        #expect(catalog.playlists(includingRecorded: true).map(\.name) == ["Sam's mix"])
        let page = try #require(catalog.playlistPage(id: "p1"))
        #expect(page.songs.map(\.id) == ["s2"] && page.total == 3 && page.playlist.owner == "sam")
    }

    @Test func records_erasedAtSignOut() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1")])
        await model.recordAlbumPage(Self.album(), songs: [Self.song("s1")])
        let file = try #require(recordsFile)
        #expect(FileManager.default.fileExists(atPath: file.path))
        model.signOut()
        await model.downloadsTeardown?.value
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Privacy at rest

    @Test func records_noURLsTokensOrAddresses() async throws {
        let model = try await signedIn()
        let song = Self.song("s1")
        await download(model, [song], reason: .album("al1"), coverArtId: "al-al1")
        await model.recordAlbumPage(Self.album(), songs: [song])
        await model.recordArtistPage(Artist(id: "va", name: "Various", albumCount: 1, coverArtId: "ar-va"), albums: [Self.album()])
        await model.recordPlaylistPage(Playlist(id: "p1", name: "Mix", songCount: 1, duration: 1, owner: "jordan", changed: .now),
                                       songs: [song], kind: .playlist)
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
        await model.recordAlbumPage(Self.album(), songs: [Self.song("s1", title: "Offline name")])
        #expect(await model.offlineCatalog.songs().map(\.title) == ["Old name"], "never offline")
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        await model.recordAlbumPage(Self.album(), songs: [Self.song("s1", title: "New name")])
        let catalog = await model.offlineCatalog
        #expect(catalog.songs().map(\.title) == ["New name"])
        #expect(catalog.albums().first?.artist == "Various")
    }

    /// D55: a song gone from the server stays on the phone; online its page simply doesn't list it, Downloads still does.
    @Test func catalog_songGoneFromServerStaysOnPhone() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1"), Self.song("s2")], reason: .album("al1"), coverArtId: "al-al1")
        await model.recordAlbumPage(Self.album(count: 1), songs: [Self.song("s1")])
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
        await model.recordArtistPage(Artist(id: "va", name: "Various", albumCount: 1, coverArtId: "ar-va"), albums: [Self.album()])
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
        await model.recordArtistPage(Artist(id: "ar-ann", name: "Ann", albumCount: 1, coverArtId: "ar-ann"), albums: [])
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
        #expect(await eventually { await store.savedLyrics(songId: "s1") != nil })
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
