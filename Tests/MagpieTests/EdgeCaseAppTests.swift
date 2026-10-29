import CarPlay
import CarPlayUI
import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Requests
import Testing
import UIKit
@testable import Magpie

// Task 8.1: real-server oddities end to end through AppModel (and the pure CarPlay rows).

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let albumListJSON = Data(#"""
{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[{"id":"al1","name":"Glasshouse","artist":"Juniper"}]}}}
"""#.utf8)
private let proxyPage = Data("<!DOCTYPE html><html><head><title>Sign in</title></head><body>Authelia</body></html>".utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let proxied = URL(string: "https://music.example.com/navidrome/")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let lidarrScope = LidarrClient(base: lidarrBase, apiKey: "key", transport: MockTransport()).instanceScope

@MainActor
@Suite(.serialized) struct EdgeCaseAppTests {
    let transport = HostSwitchTransport()
    let engine = FakeEngine()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "EdgeCaseAppTests.\(UUID().uuidString)")!

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    func stubNavidrome() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/rest/getAlbumList2", body: albumListJSON)
        t.stub(pathSuffix: "/rest/star", body: ok)
        t.stub(pathSuffix: "/rest/scrobble", body: ok)
        t.stub(pathSuffix: "/api/song", body: Data(#"[{"id":"s1","title":"Bloom","artist":"Juniper"}]"#.utf8),
               headers: ["X-Total-Count": "1"])
    }

    func tearDown(_ model: AppModel) {
        model.signOut()
        store.clear()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    // MARK: Reverse proxy base path

    /// Review focus 1, end to end: Navidrome at `https://host/navidrome/` (as typed, trailing slash). Every request
    /// the app makes (probe, login, Subsonic, native API, scrobble, star) and every URL it hands out (stream,
    /// cover art) keeps the base path.
    @Test func reverseProxyBasePathEverywhere() async throws {
        stubNavidrome()
        let model = makeModel()
        try await model.signIn(urls: [proxied], username: "admin", password: "pw")
        _ = try await model.request { try await $0.albumList(.newest, size: 24, offset: 0) }
        try await model.refreshMatchIndex()
        let song = Song(id: "s1", title: "Bloom", artist: "Juniper", album: "Glasshouse", duration: 200)
        await model.toggleStar(song)
        model.play([song], startAt: 0)
        await model.player.waitForPendingScrobbles()

        let paths = transport.inner.requests.compactMap { $0.url?.path }
        #expect(paths.contains("/navidrome/rest/ping"))
        #expect(paths.contains("/navidrome/auth/login"))
        #expect(paths.contains("/navidrome/rest/getAlbumList2"))
        #expect(paths.contains("/navidrome/api/song"))
        #expect(paths.contains("/navidrome/rest/star"))
        #expect(paths.contains("/navidrome/rest/scrobble"))
        #expect(paths.allSatisfy { $0.hasPrefix("/navidrome/") }, "\(paths.filter { !$0.hasPrefix("/navidrome/") })")
        #expect(paths.allSatisfy { !$0.contains("//") })
        let stream = try #require(engine.setItemsCalls.last?.items.first?.1)
        #expect(stream.host == "music.example.com" && stream.path == "/navidrome/rest/stream")
        #expect(model.coverArtURL("al1", size: 300)?.path == "/navidrome/rest/getCoverArt")
        tearDown(model)
    }

    // MARK: Proxy HTML pages

    /// An auth proxy in front of Navidrome answers its HTML sign-in page with 200: sign-in fails calmly with a
    /// message that says what is wrong, and nothing is saved.
    @Test func proxySignInPageAtConnect() async throws {
        transport.inner.stub(pathSuffix: "/rest/ping", body: proxyPage)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: proxyPage)
        let model = makeModel()
        var thrown: Error?
        do { try await model.signIn(urls: [proxied], username: "admin", password: "pw") } catch { thrown = error }
        let error = try #require(thrown)
        #expect(model.session == nil)
        #expect(store.load().saved == nil)
        let message = ConnectErrorCopy.message(for: error)
        #expect(message == ConnectErrorCopy.notAMusicServer, "got: \(message)")
    }

    /// The proxy's session expires mid-session: browsing says what happened, never fails over, never crashes.
    @Test func proxySignInPageMidSession() async throws {
        stubNavidrome()
        transport.inner.stub(pathSuffix: "/rest/getArtists", body: proxyPage)
        let model = makeModel()
        try await model.signIn(urls: [proxied], username: "admin", password: "pw")
        let probes = transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/ping") == true }.count
        var thrown: Error?
        do { _ = try await model.request { try await $0.artists() } } catch { thrown = error }
        let error = try #require(thrown)
        #expect(error as? NavidromeError == .unexpectedResponse)
        #expect(BrowseErrorCopy.message(for: error) == BrowseErrorCopy.unexpectedResponse)
        #expect(transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/ping") == true }.count == probes)
        tearDown(model)
    }

    /// Fix round 1: real JSON in a shape Magpie can't read (a newer Navidrome) is not blamed on a proxy.
    @Test func unexpectedJSONShapeIsNotBlamedOnAProxy() async throws {
        stubNavidrome()
        transport.inner.stub(pathSuffix: "/rest/getArtists", body: Data(
            #"{"subsonic-response":{"status":"ok","version":"1.16.1","artists":{"index":"changed"}}}"#.utf8))
        let model = makeModel()
        try await model.signIn(urls: [proxied], username: "admin", password: "pw")
        var thrown: Error?
        do { _ = try await model.request { try await $0.artists() } } catch { thrown = error }
        let error = try #require(thrown)
        #expect(error as? NavidromeError == .unexpectedData)
        #expect(BrowseErrorCopy.message(for: error) == BrowseErrorCopy.unexpectedData)
        #expect(ConnectErrorCopy.message(for: error) == ConnectErrorCopy.unexpectedData)
        #expect(BrowseErrorCopy.unexpectedData != BrowseErrorCopy.unexpectedResponse)
        tearDown(model)
    }

    /// Subsonic `status: "failed"` in a 200 (e.g. an album deleted while browsing): a calm message, no failover.
    @Test func subsonicFailedIsCalm() async throws {
        stubNavidrome()
        transport.inner.stub(pathSuffix: "/rest/getAlbum", body: Data(
            #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"Album not found"}}}"#.utf8))
        let model = makeModel()
        try await model.signIn(urls: [home, proxied], username: "admin", password: "pw")
        var thrown: Error?
        do { _ = try await model.request { try await $0.album(id: "gone") } } catch { thrown = error }
        let error = try #require(thrown)
        #expect(!AppModel.isConnectionError(error))
        #expect(model.session?.activeBase == home)
        #expect(!BrowseErrorCopy.message(for: error).contains("Album not found"), "server text never shown raw")
        tearDown(model)
    }

    // MARK: Server down mid-play

    /// The home address dies mid-song: the engine reports the item failed, the player pauses on that song with
    /// the error (no racing through the queue), and the app moves to the away address with rebuilt URLs.
    @Test func serverDownMidPlayPausesAndFailsOver() async throws {
        stubNavidrome()
        let model = makeModel()
        try await model.signIn(urls: [home, proxied], username: "admin", password: "pw")
        let songs = (1...3).map { Song(id: "s\($0)", title: "T\($0)", artist: "A", album: "B", duration: 200) }
        model.play(songs, startAt: 0)
        let current = try #require(model.player.queue.current?.id)

        transport.setDown([home.host!])
        model.player.handle(.failed(current, "The server stopped answering."))
        #expect(!model.player.isPlaying)
        #expect(model.player.lastError != nil)
        #expect(model.player.queue.current?.id == current, "no skipping ahead on a dead server")

        for _ in 0..<300 where model.session?.activeBase != proxied { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.session?.activeBase == proxied)
        let rebuilt = try #require(engine.setItemsCalls.last?.items)
        #expect(rebuilt.allSatisfy { $0.1.host == "music.example.com" })
        tearDown(model)
    }

    // MARK: Empty library

    /// A brand-new server with nothing on it: sign-in works, the index is empty, every CarPlay list says so.
    @Test func emptyLibraryFirstRun() async throws {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/rest/getAlbumList2", body: Data(#"{"subsonic-response":{"status":"ok","albumList2":{}}}"#.utf8))
        t.stub(pathSuffix: "/rest/getArtists", body: Data(#"{"subsonic-response":{"status":"ok","artists":{}}}"#.utf8))
        t.stub(pathSuffix: "/rest/getPlaylists", body: Data(#"{"subsonic-response":{"status":"ok","playlists":{}}}"#.utf8))
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.matchIndexSettled()
        #expect(await model.matchIndex?.index.count == 0)
        let albums = try await model.request { try await $0.albumList(.newest, size: 24, offset: 0) }
        let artists = try await model.request { try await $0.artists() }
        let playlists = try await model.request { try await $0.playlists() }
        #expect(CarPlayRows.home([.jumpBackIn, .recentlyAdded, .mostPlayed].map { CPHomeShelf(section: $0, items: albums.map(CPHomeShelf.Item.album)) }) == CarPlayRows.state(.empty))
        #expect(CarPlayRows.artists(artists) == CarPlayRows.state(.empty))
        #expect(CarPlayRows.playlists(playlists) == CarPlayRows.state(.empty))
        model.play([], startAt: 0)
        #expect(model.player.queue.current == nil)
        tearDown(model)
    }

    // MARK: Lidarr

    /// Lidarr behind a proxy that answers HTML: Connect says it doesn't look like Lidarr, and nothing is saved.
    @Test func lidarrHTMLAtConnect() async throws {
        stubNavidrome()
        transport.inner.stub(pathSuffix: "/api/v1/system/status", body: proxyPage)
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        var thrown: Error?
        do { _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key") } catch { thrown = error }
        let error = try #require(thrown)
        #expect(LidarrConnectCopy.message(for: error, url: lidarrBase) == LidarrConnectCopy.notLidarr)
        #expect(model.lidarr == nil && lidarrStore.load() == nil)
        tearDown(model)
    }

    /// The key was regenerated in Lidarr after connecting: Settings says the key no longer works (not "not
    /// answering"), and with changes allowed, Try waits and the gate writes nothing.
    @Test func lidarrKeyRejectedAfterConnect() async throws {
        stubNavidrome()
        let rejected = OSAllocatedUnfairLock(initialState: false)
        let t = transport.inner
        t.stub(pathSuffix: "/api/v1/system/status") { _ in
            rejected.withLock { $0 } ? .init(status: 401)
                : .init(status: 200, body: Data(#"{"version":"3.2.0","authentication":"forms"}"#.utf8))
        }
        t.stub(pathSuffix: "/api/v1/rootfolder") { _ in
            rejected.withLock { $0 } ? .init(status: 401) : .init(status: 200, body: Data(#"[{"id":1,"path":"/music"}]"#.utf8))
        }
        let recording = MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d")!
        t.stub(pathSuffix: "/ws/2/recording/\(recording.rawValue)", body: Data(#"""
        {"id":"\#(recording.rawValue)","title":"Harbour Lights","artist-credit":[{"artist":{"id":"64db764c-2251-4f95-aa40-10fc91d509d8"}}],
         "releases":[{"id":"545b96d6-c867-3053-9548-3e8635390e38","title":"The Cat Is Out","status":"Official",
           "release-group":{"id":"01a340b4-1d99-4083-ad92-fa2803368bed","primary-type":"Album","secondary-types":[]}}]}
        """#.utf8))
        for suffix in ["/api/v1/artist", "/api/v1/album", "/api/v1/artist/lookup"] { t.stub(pathSuffix: suffix, status: 401) }
        for method in ["PUT", "POST", "DELETE"] { t.stub(method: method, pathSuffix: "", status: 401) }
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(base: lidarrBase, scope: lidarrScope, fastStartProfileId: 4,
                                                              findsMetadataProfileId: 3, magpieTagId: 1))
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        #expect(model.tryAvailability == .available(.patient))

        rejected.withLock { $0 = true }
        let audit = try #require(await model.lidarrAudit())
        #expect(audit.keyRejected)
        #expect(LidarrSummary.status(audit) == LidarrSummary.keyRejected)
        #expect(LidarrSummary.lines(for: audit).first?.value == LidarrSummary.keyRejected)

        let id = try await model.tryRecording(ExternalRecording(recordingMBID: recording, title: "Harbour Lights",
                                                                artist: "Judie Tzuke", source: .listenBrainz))
        for _ in 0..<300 {
            if case .waiting = model.magpieRequest(id)?.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .waiting(let reason, _) = model.magpieRequest(id)?.state else {
            Issue.record("expected waiting, got \(String(describing: model.magpieRequest(id)?.state))"); return
        }
        #expect(reason.kind == .serviceUnavailable)
        let writes = t.requests.filter { $0.httpMethod != "GET" && $0.url?.port == 8686 }
        #expect(writes.isEmpty, "\(writes.map { "\($0.httpMethod!) \($0.url!.path)" })")
        #expect(await model.changeLog().isEmpty)
        tearDown(model)
    }
}

// MARK: - CarPlay rows with real-world names

@MainActor
@Suite struct CarPlayEdgeCaseTests {
    static let long = String(repeating: "Symphony No. 9 in D minor, Op. 125 \u{201C}Choral\u{201D}: IV. Presto — ", count: 40)
    static let names = [long, "東京事変 – 群青日和", "مُحَمَّد عَبْد الوَهَّاب", "Beyoncé 🐝👑🏽", "Z\u{0351}\u{036B}\u{0343}a\u{0310}l\u{0352}g\u{030C}o",
                        "\u{202E}reversed\u{202C}", "Line\nbreak\ttab", ""]

    static func album(_ i: Int, name: String, id: String? = nil) -> Album {
        Album(id: id ?? "al\(i)", name: name, artist: name, songCount: 1, duration: 100, coverArtId: nil,
              songs: [Song(id: "s\(i)", title: name, artist: name, album: name, duration: 100)])
    }

    /// Very long and unusual titles: rows keep their text (the car truncates), CarPlay items take it without
    /// crashing, and list limits still hold.
    @Test func longAndUnicodeTitles() {
        let albums = Self.names.enumerated().map { Self.album($0.offset, name: $0.element) }
        let screens: [[CPSectionModel]] = [
            CarPlayRows.albums(albums),
            CarPlayRows.home([.jumpBackIn, .recentlyAdded, .mostPlayed].map { CPHomeShelf(section: $0, items: albums.map(CPHomeShelf.Item.album)) }),
            CarPlayRows.album(albums[0], playingId: nil),
            CarPlayRows.artists(albums.map { Artist(id: $0.id, name: $0.name, albumCount: 1) }),
            CarPlayRows.searchResults(LibrarySearchResult(songs: albums.flatMap { $0.songs ?? [] }, albums: albums, artists: []),
                                      playingId: "s1"),
        ]
        for sections in screens {
            let fitted = clamp(sections, maxItems: 12, maxSections: 5)
            #expect(fitted.flatMap(\.rows).count <= 12)
            for row in fitted.flatMap(\.rows) {
                let item = CPListItem(text: row.title, detailText: row.detail)
                #expect(item.text == row.title)
            }
        }
        #expect(CarPlayRows.albums(albums).flatMap(\.rows).first?.title == Self.long, "never cut by Magpie")
        #expect(CPDestination.album(id: "x", title: Self.long).title == Self.long)
    }

    /// Empty names (tags with no album or artist): a row never shows blank text on the car screen.
    @Test func emptyNamesNeverShowBlankRows() {
        let album = Self.album(1, name: "")
        let rows = [
            CarPlayRows.albums([album]),
            CarPlayRows.home([CPHomeShelf(section: .jumpBackIn, items: [.album(album)]), CPHomeShelf(section: .genres, items: [.genreGroup(id: "g", name: "", albumCount: 1)])]),
            CarPlayRows.artists([Artist(id: "ar1", name: "", albumCount: 1)]),
            CarPlayRows.playlists([Playlist(id: "p1", name: "", songCount: 1, duration: 1)]),
            CarPlayRows.album(album, playingId: nil),
            CarPlayRows.playlist(Playlist(id: "p1", name: "", songCount: 1, duration: 1), songs: album.songs!, playingId: nil),
            CarPlayRows.artist(Artist(id: "ar1", name: "", albumCount: 1), albums: [album]),
            CarPlayRows.searchResults(LibrarySearchResult(songs: album.songs!, albums: [album], artists: []), playingId: nil),
        ].flatMap { $0.flatMap(\.rows) } + CarPlayRows.searchItems(LibrarySearchResult(songs: album.songs!, albums: [album], artists: []))
        for row in rows {
            #expect(!row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "blank row \(row.id)")
        }
        if case .open(let destination) = CarPlayRows.albums([album]).first?.rows.first?.action {
            #expect(!destination.title.isEmpty, "blank template title")
        }
    }

    /// Duplicate ids in one server page: row ids stay unique within a list (the controller updates rows by id).
    @Test func duplicateIdsGiveUniqueRowIds() {
        let a = Self.album(1, name: "Same", id: "dup"), b = Self.album(2, name: "Same again", id: "dup")
        let song = Song(id: "dup", title: "Song", artist: "A", album: "B", duration: 100)
        let screens: [[CPSectionModel]] = [
            CarPlayRows.albums([a, b]),
            CarPlayRows.home([CPHomeShelf(section: .jumpBackIn, items: [.album(a), .album(b)]), CPHomeShelf(section: .recentlyAdded, items: [.album(a), .album(b)])]),
            CarPlayRows.artists([Artist(id: "dup", name: "One", albumCount: 1), Artist(id: "dup", name: "Two", albumCount: 1)]),
            CarPlayRows.playlists([Playlist(id: "dup", name: "One", songCount: 1, duration: 1),
                                   Playlist(id: "dup", name: "Two", songCount: 1, duration: 1)]),
            CarPlayRows.playlist(Playlist(id: "p", name: "P", songCount: 2, duration: 2), songs: [song, song], playingId: "dup"),
            CarPlayRows.artist(Artist(id: "ar", name: "A", albumCount: 2), albums: [a, b]),
            CarPlayRows.searchResults(LibrarySearchResult(songs: [song, song], albums: [a, b], artists: []), playingId: nil),
        ]
        for sections in screens {
            let ids = sections.flatMap(\.rows).map(\.id)
            #expect(Set(ids).count == ids.count, "duplicate row ids: \(ids)")
        }
        let items = CarPlayRows.searchItems(LibrarySearchResult(songs: [song, song], albums: [a, b], artists: [])).map(\.id)
        #expect(Set(items).count == items.count)
    }

    /// An album with no cover: no artwork key (the row shows the placeholder), and no cover URL is built.
    @MainActor @Test func albumWithNoCover() {
        let album = Self.album(1, name: "Bare")
        #expect(CarPlayRows.albums([album]).flatMap(\.rows).allSatisfy { $0.artworkKey == nil })
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             lidarrStore: MemoryLidarrStore(), matchIndexDirectory: nil, dataDirectory: nil,
                             engine: FakeEngine(), systemNowPlaying: false, notifications: false)
        #expect(model.coverArtURL(nil, size: 300) == nil)
    }
}
