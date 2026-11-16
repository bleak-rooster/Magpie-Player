import DesignSystem
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import os
import SwiftUI
import Testing
import UIKit
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt-o3","subsonicToken":"tok-o3","token":"jwt-o3","username":"jordan"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

/// A Subsonic song as JSON.
private func songJSON(_ id: String, album: String = "al1", artist: String = "Ann", artistId: String = "ar-ann",
                      track: Int) -> String {
    #"{"id":"\#(id)","title":"T\#(id)","artist":"\#(artist)","artistId":"\#(artistId)","album":"Album \#(album)","albumId":"\#(album)","duration":200,"coverArt":"mf-\#(id)","track":\#(track)}"#
}

/// Round 28 O3 (owner, 2026-11-15, item 1: "when music is downloaded, you should be able to access the page with that
/// music, like an album should still open the album of the downloaded music … In offline mode, only downloaded songs
/// are visible within albums, artists, songs, etc."): the album, artist and playlist pages offline, the phone's copy
/// when an online read fails, the queue and the lyrics pane (D341, D342, D344). Against stubs, never a real server.
@MainActor @Suite(.serialized) final class OfflinePagesAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflinePagesAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "OfflinePagesAppTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    let network = FakeNetwork(.wifi)
    /// The status getAlbum, getArtist and getPlaylist answer with (a test turns them into a proxy's 503).
    let pageStatus = OSAllocatedUnfairLock(initialState: 200)

    init() {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2",
                             body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}"#.utf8))
        let songs = (1...3).map { songJSON("s\($0)", track: $0) }.joined(separator: ",")
        page("/rest/getAlbum", #""album":{"id":"al1","name":"Album al1","artist":"Various","artistId":"va","year":2004,"genre":"Jazz","songCount":3,"duration":600,"coverArt":"al-al1","song":[\#(songs)]}"#)
        page("/rest/getArtist", #""artist":{"id":"va","name":"Various","albumCount":1,"album":[{"id":"al1","name":"Album al1","artist":"Various","artistId":"va","year":2004,"songCount":3,"duration":600,"coverArt":"al-al1"}]}"#)
        page("/rest/getPlaylist", #""playlist":{"id":"p1","name":"Sam's mix","owner":"sam","songCount":3,"duration":600,"entry":[\#(songs)]}"#)
    }

    private func page(_ path: String, _ body: String) {
        let data = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
        let status = pageStatus
        transport.inner.stub(pathSuffix: path) { _ in
            let code = status.withLock { $0 }
            // Fix round 1 (I1): 70 is the library's own "not found" (a Subsonic error in a 200), an answer, not silence.
            if code == 70 {
                return MockTransport.Response(status: 200, body: Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"Not found"}}}"#.utf8))
            }
            return MockTransport.Response(status: code, body: code == 200 ? data : Data("<html>Bad gateway</html>".utf8))
        }
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                 matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                 network: network, audioFetcher: FakeFetcher())
    }

    func signedIn() async throws -> AppModel {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "jordan", password: "pw-o3")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        return model
    }

    static func song(_ id: String, album: String = "al1", artist: String = "Ann", artistId: String = "ar-ann",
                     track: Int? = nil) -> Song {
        Song(id: id, title: "T\(id)", artist: artist, artistId: artistId, album: "Album \(album)", albumId: album,
             track: track, duration: 200, coverArtId: "mf-\(id)")
    }

    func download(_ model: AppModel, _ songs: [Song], reason: DownloadReason = .song) async {
        model.download(songs, reason: reason)
        await model.downloads!.settled()
    }

    func manualOffline(_ model: AppModel) {
        model.updatePreferences { $0.downloads.offlineMode = .on }
    }

    /// Leaves Offline mode; `isOffline` holds until the login answers (O1 design H1), so wait for it.
    func backOnline(_ model: AppModel) async {
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually { !model.isOffline })
    }

    func album(_ model: AppModel, _ id: String = "al1", onScreen: PageSource? = nil) async -> AlbumView.Outcome? {
        var result: AlbumView.Outcome?
        await AlbumView.load(model, albumId: id, onScreen: onScreen) { result = $0 }
        return result
    }

    func artist(_ model: AppModel, _ id: String, onScreen: PageSource? = nil) async -> ArtistView.Outcome? {
        var result: ArtistView.Outcome?
        await ArtistView.load(model, artistId: id, onScreen: onScreen) { result = $0 }
        return result
    }

    func playlist(_ model: AppModel, _ id: String = "p1", fromPhone: Bool = false,
                  onScreen: PageSource? = nil) async -> PlaylistView.Outcome? {
        var result: PlaylistView.Outcome?
        await PlaylistView.load(model, playlistId: id, fromPhone: fromPhone, onScreen: onScreen) { result = $0 }
        return result
    }

    // MARK: - Album (D341)

    @Test func album_offlineShowsOnlyDownloadedWithCount() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s2", track: 2)])
        guard case .shown(let online)? = await album(model) else { Issue.record("no album online"); return }
        #expect(online.source == .server && online.album.songs?.count == 3)
        manualOffline(model)
        guard case .shown(let shown)? = await album(model) else { Issue.record("no album offline"); return }
        #expect(shown.source == .phone)
        #expect(shown.album.songs?.map(\.id) == ["s2"], "only the song on the phone")
        #expect(shown.album.name == "Album al1" && shown.album.artist == "Various" && shown.album.year == 2004,
                "the header as recorded")
        #expect(shown.onPhone == 1 && shown.total == 3)
        #expect(OfflinePageCopy.onPhone(shown.onPhone, of: shown.total) == "1 of 3 songs on this phone")
        #expect(OfflinePageCopy.onPhone(3, of: 3) == nil, "a whole album says nothing")
        #expect(OfflinePageCopy.onPhone(2, of: nil) == "2 songs on this phone")
        #expect(OfflinePageCopy.onPhone(1, of: nil) == "1 song on this phone")
        // An album with nothing on the phone says so.
        guard case .notOnPhone? = await album(model, "al-none") else { Issue.record("expected not on phone"); return }
    }

    @Test func album_offlineHidesServerActions() async throws {
        #expect(AlbumView.showsServerActions(.server, offline: false, id: "al1"))
        #expect(!AlbumView.showsServerActions(.phone, offline: true, id: "al1"), "Favourite, Add to playlist, Reload artwork")
        #expect(!AlbumView.showsServerActions(.phoneCopy, offline: false, id: "al1"))
        #expect(!AlbumView.showsServerActions(.server, offline: false, id: "magpie.local:x"))
        // Remove download stays; Download itself needs the server.
        #expect(AlbumView.showsDownload(.phone, status: .downloaded))
        #expect(!AlbumView.showsDownload(.phone, status: .none))
        #expect(AlbumView.showsDownload(.server, status: .none))
    }

    @Test func album_onlineReadRecordsThePage() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", track: 1)])
        _ = await album(model)
        #expect(await eventually { await model.downloads!.store.records().albums["al1"]?.songIds == ["s1", "s2", "s3"] })
        // Offline nothing is written.
        manualOffline(model)
        let before = await model.downloads!.store.records()
        _ = await album(model)
        #expect(await model.downloads!.store.records() == before)
    }

    // MARK: - Artist (D341)

    @Test func artist_albumArtistOpensOffline() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", track: 1)])
        _ = await album(model)   // recorded: its album artist is Various
        guard case .shown(let online)? = await artist(model, "va") else { Issue.record("no artist online"); return }
        #expect(online.source == .server)
        #expect(await eventually { await model.downloads!.store.records().artists["va"]?.albumIds == ["al1"] })
        manualOffline(model)
        guard case .shown(let page)? = await artist(model, "va") else { Issue.record("no artist offline"); return }
        #expect(page.source == .phone && page.artist.name == "Various")
        #expect(page.albums.map(\.id) == ["al1"] && page.songs.isEmpty)
        #expect(!model.automixAvailable(artistId: "va", albums: page.albums), "Automix hidden offline (D305)")
    }

    @Test func artist_featuredSongsUnderSongsOnThisPhone() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", track: 1)])
        _ = await album(model)
        manualOffline(model)
        guard case .shown(let page)? = await artist(model, "ar-ann") else { Issue.record("no track artist page"); return }
        #expect(page.albums.isEmpty, "Ann isn't the album artist")
        #expect(page.songs.map(\.id) == ["s1"])
        #expect(OfflinePageCopy.songsOnThisPhone == "Also on this phone")   // fix round 1 (design M8)
        // Play plays what's on the phone, asking nothing.
        let sent = transport.inner.requests.count
        #expect(ArtistView.phoneSongs(page).map(\.id) == ["s1"])
        #expect(transport.inner.requests.count == sent)
    }

    // MARK: - Playlist (D341)

    @Test func playlist_offlineOwnerCaption() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s3", track: 3)])
        guard case .shown(let online)? = await playlist(model) else { Issue.record("no playlist online"); return }
        #expect(online.source == .server && online.songs.count == 3)
        #expect(await eventually { await model.downloads!.store.records().playlists["p1"] != nil }, "recorded (Q3)")
        manualOffline(model)
        guard case .shown(let shown)? = await playlist(model) else { Issue.record("no playlist offline"); return }
        #expect(shown.source == .phone && shown.playlist.owner == "sam")
        #expect(OwnerCaption.text(owner: shown.playlist.owner, signedInUser: model.session?.username) == "sam",
                "D205's caption, offline too")
        #expect(!PlaylistView.isEditable(canEdit: true, fromPhone: false, source: shown.source),
                "no renaming, deleting or removing songs from the phone's page")
    }

    @Test func playlist_partlyDownloadedCount() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", track: 1), Self.song("s3", track: 3)])
        _ = await playlist(model)
        #expect(await eventually { await model.downloads!.store.records().playlists["p1"] != nil })
        manualOffline(model)
        guard case .shown(let shown)? = await playlist(model) else { Issue.record("no playlist offline"); return }
        #expect(shown.songs.map(\.id) == ["s1", "s3"], "in the playlist's order")
        #expect(shown.onPhone == 2 && shown.total == 3)
        #expect(OfflinePageCopy.onPhone(shown.onPhone, of: shown.total) == "2 of 3 songs on this phone")
    }

    // MARK: - The phone's copy when the server fails (D341)

    @Test func fallback_failedReadShowsThePhonesCopy() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", track: 1)])
        _ = await album(model)
        _ = await playlist(model)
        #expect(await eventually { await model.downloads!.store.records().playlists["p1"] != nil })
        pageStatus.withLock { $0 = 503 }   // a proxy in front of a stopped library
        guard case .shown(let shown)? = await album(model) else { Issue.record("no phone copy"); return }
        #expect(shown.source == .phoneCopy && shown.album.songs?.map(\.id) == ["s1"])
        guard case .shown(let list)? = await playlist(model) else { Issue.record("no phone copy"); return }
        #expect(list.source == .phoneCopy && list.songs.map(\.id) == ["s1"])
        #expect(OfflinePageCopy.phoneCopy == "Couldn\u{2019}t reach your library. Showing what\u{2019}s on this phone.")
        #expect(!PageSource.fallsBack(after: CancellationError()), "a load cut short shows nothing new (D77)")
        #expect(!PageSource.fallsBack(after: URLError(.cancelled)))
    }

    @Test func fallback_noCopyKeepsTheError() async throws {
        let model = try await signedIn()
        pageStatus.withLock { $0 = 503 }
        guard case .failed? = await album(model) else { Issue.record("expected the error"); return }
        guard case .failed? = await artist(model, "va") else { Issue.record("expected the error"); return }
    }

    @Test func pageKey_recordChangeReloads() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", track: 1)])
        manualOffline(model)
        let key = model.offlinePageKey
        await backOnline(model)
        _ = await album(model)
        #expect(await eventually { await model.downloads!.store.records().albums["al1"] != nil })
        manualOffline(model)
        #expect(model.offlinePageKey != key, "a record written meanwhile reloads the offline page")
    }

    // MARK: - Queue (D342)

    @Test func queue_offlineLabelsAndSkips() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s2")])
        model.play([Self.song("s1"), Self.song("s2"), Self.song("s3")], startAt: 0)
        manualOffline(model)
        let onPhone = { (id: String) in model.downloads?.localFiles[id] != nil }
        #expect(QueueView.skippedOffline("s1", offline: model.isOffline, onPhone: onPhone))
        #expect(!QueueView.skippedOffline("s2", offline: model.isOffline, onPhone: onPhone))
        #expect(QueueView.skippedOffline("s3", offline: model.isOffline, onPhone: onPhone))
        #expect(model.player.queue.upcoming.map(\.song.id).contains("s3"), "every entry stays")
        #expect(OfflinePageCopy.notOnThisPhone == "Not on this phone")
        #expect(OfflinePageCopy.notOnThisPhoneValue == "Not on this phone, skipped while offline")
        #expect(!model.player.isPlayable(Self.song("s3")) && model.player.isPlayable(Self.song("s2")), "skipped (today's player)")
    }

    @Test func queue_labelGoesBackOnline() async throws {
        let model = try await signedIn()
        manualOffline(model)
        let onPhone = { (id: String) in model.downloads?.localFiles[id] != nil }
        #expect(QueueView.skippedOffline("s1", offline: model.isOffline, onPhone: onPhone))
        await backOnline(model)
        #expect(!QueueView.skippedOffline("s1", offline: model.isOffline, onPhone: onPhone))
    }

    // MARK: - Lyrics pane (D344)

    @Test func lyrics_offlineShowsKept() async throws {
        let model = try await signedIn()
        let song = Self.song("s1")
        await download(model, [song])
        let lyrics = Lyrics(synced: false, lines: [.init(start: nil, text: "Kept on the phone")])
        model.keepLyricsOnPhone("s1", .lines(lyrics, .library))
        await model.downloads!.settled()
        #expect(await eventually { await model.downloads!.store.savedLyrics(songId: "s1") != nil })
        manualOffline(model)
        let shown = try await model.lyricsForPane(song, fresh: true)
        guard case .lines(let kept, .library)? = shown else { Issue.record("no kept lyrics offline"); return }
        #expect(kept.lines.map(\.text) == ["Kept on the phone"])
        #expect(try await model.lyricsForPane(Self.song("s9"), fresh: true) == nil)
        #expect(LyricsContent.emptyTitle(offline: true) == "You're offline", "none kept: D313's line")
        #expect(LyricsContent.reloadKey(songId: "s1", offline: true) != LyricsContent.reloadKey(songId: "s1", offline: false),
                "the pane reads again when Magpie goes offline or comes back")
    }

    // MARK: - Fix round 1

    /// I1: only silence (no answer, a proxy or portal page, Offline mode) falls back; the library's own answer — a Subsonic
    /// error such as 70 (gone), or a refused sign-in — keeps today's error.
    @Test func fallback_libraryAnswerKeepsTheError() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", track: 1)])
        _ = await album(model)
        #expect(await eventually { await model.downloads!.store.records().albums["al1"] != nil })
        pageStatus.withLock { $0 = 70 }
        guard case .failed? = await album(model) else { Issue.record("a Subsonic error must not show the phone's copy"); return }
        #expect(!PageSource.fallsBack(after: NavidromeError.api(code: 70, message: "Not found")))
        #expect(!PageSource.fallsBack(after: NavidromeError.badCredentials))
        #expect(!PageSource.fallsBack(after: NavidromeError.http(status: 401)))
        #expect(PageSource.fallsBack(after: URLError(.cannotConnectToHost)))
        #expect(PageSource.fallsBack(after: NavidromeError.http(status: 503)))
        #expect(PageSource.fallsBack(after: NavidromeError.unexpectedResponse))
        #expect(PageSource.fallsBack(after: NavidromeError.http(status: 302)), "a refused redirect")
        #expect(PageSource.fallsBack(after: AppModel.forcedOfflineError))
    }

    /// I2: a server page on screen stays on a failed read (Z2's quiet failure); the phone's copy shows only over nothing,
    /// or over what already came from the phone.
    @Test func fallback_serverPageOnScreenStays() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", track: 1)])
        guard case .shown(let server)? = await album(model) else { Issue.record("no album"); return }
        #expect(await eventually { await model.downloads!.store.records().albums["al1"] != nil })
        pageStatus.withLock { $0 = 503 }
        guard case .failed(let error)? = await album(model, onScreen: .server) else {
            Issue.record("a server page on screen must not be swapped for the phone's copy"); return
        }
        let kept = Loadable<AlbumView.Shown>.loaded(server).failing(error)
        #expect(kept.value?.source == .server && kept.value?.album.songs?.count == 3, "the server's page stays")
        guard case .shown(let copy)? = await album(model, onScreen: .phoneCopy) else { Issue.record("no copy"); return }
        #expect(copy.source == .phoneCopy)
        guard case .failed? = await artist(model, "va", onScreen: .server) else { Issue.record("artist swapped"); return }
        guard case .failed? = await playlist(model, onScreen: .server) else { Issue.record("playlist swapped"); return }
    }

    /// M3: the artist page's copy from the phone when its read fails.
    @Test func fallback_artistShowsThePhonesCopy() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", track: 1)])
        _ = await album(model)
        _ = await artist(model, "va")
        #expect(await eventually { await model.downloads!.store.records().artists["va"] != nil })
        pageStatus.withLock { $0 = 503 }
        guard case .shown(let copy)? = await artist(model, "va") else { Issue.record("no phone copy"); return }
        #expect(copy.source == .phoneCopy && copy.albums.map(\.id) == ["al1"])
    }

    /// M1: a download started on the album page records it into the downloads the page loaded with, never another
    /// account's.
    @Test func album_downloadStartRecordsIntoTheLoadTimeStore() async throws {
        let model = try await signedIn()
        guard case .shown(let shown)? = await album(model) else { Issue.record("no album"); return }
        #expect(shown.target === model.downloads)
        model.signOut()
        try await model.signIn(urls: [home], username: "jordan", password: "pw-o3")
        await model.downloads!.settled()
        await download(model, [Self.song("s1", track: 1)])
        await AlbumView.recordStartedDownload(shown, model: model)
        #expect(await model.downloads!.store.records().albums["al1"] == nil, "the old page's store is gone")
    }

    /// M3: a page read that answers after a sign-out and a new sign-in records nothing in the new account's store.
    @Test func records_goIntoTheStoreCapturedBeforeTheRead() async throws {
        let model = try await signedIn()
        let gate = D1Gate()
        let reached = OSAllocatedUnfairLock(initialState: false)
        let armed = OSAllocatedUnfairLock(initialState: true)
        transport.setHook { request in
            guard request.url?.path.hasSuffix("/rest/getAlbum") == true, armed.withLock({ $0 }) else { return }
            reached.withLock { $0 = true }
            await gate.wait()
        }
        let load = Task { await self.album(model) }
        #expect(await eventually { reached.withLock { $0 } })
        armed.withLock { $0 = false }
        model.signOut()
        try await model.signIn(urls: [home], username: "jordan", password: "pw-o3")
        await model.downloads!.settled()
        await download(model, [Self.song("s1", track: 1)])
        gate.open()
        _ = await load.value
        transport.setHook(nil)
        #expect(await model.downloads!.store.records().albums["al1"] == nil)
    }

    /// M3: the artist page's Play and Shuffle on the phone's page play what's here and ask the server nothing.
    @Test func artist_playFromThePhoneAsksNothing() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1", track: 1)])
        _ = await album(model)
        manualOffline(model)
        guard case .shown(let page)? = await artist(model, "ar-ann") else { Issue.record("no page"); return }
        let sent = transport.inner.requests.count
        ArtistView.play(page, model: model, shuffled: false)
        #expect(model.player.queue.current?.song.id == "s1")
        ArtistView.play(page, model: model, shuffled: true)
        #expect(transport.inner.requests.count == sent, "nothing asked of the server")
    }

    /// M3: the queue view itself labels the entries not on the phone offline, and only those.
    @Test func queue_viewLabelsSkippedRows() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s2"), Self.song("s4")])
        model.play([Self.song("s1"), Self.song("s2"), Self.song("s3"), Self.song("s4")], startAt: 0)
        manualOffline(model)   // Offline mode moves on from s1 (not here) to s2; s3 and s4 are up next
        let labelled = OSAllocatedUnfairLock(initialState: [String: Bool]())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 2000)
        window.rootViewController = UIHostingController(rootView: QueueView()
            .environment(model)
            .magpieTheme(Theme())
            .environment(\.queueRowProbe, QueueRowProbe { id, skipped in labelled.withLock { $0[id] = skipped } }))
        window.isHidden = false
        let drawn = await eventually { labelled.withLock { $0.keys.count } >= 2 }
        #expect(drawn, "queue \(model.player.queue.current?.song.id ?? "-") \(model.player.queue.upcoming.map(\.song.id)) rows \(labelled.withLock { $0 })")
        #expect(labelled.withLock { $0 } == ["s3": true, "s4": false], "\(labelled.withLock { $0 })")
        window.isHidden = true
    }

    /// Design H1, M8, M10: one answer per page; the artist's other songs are "Also on this phone"; the phone's pages' row
    /// menus hold only what works without the server.
    @Test func phonePages_oneAnswerAndOfflineMenus() {
        #expect(!OfflinePageCopy.showsMark(.phone, onPhone: 1, total: 3), "the count line says it")
        #expect(!OfflinePageCopy.showsMark(.phone, onPhone: 2, total: nil))
        #expect(OfflinePageCopy.showsMark(.phone, onPhone: 3, total: 3), "all here: the mark says Downloaded")
        #expect(OfflinePageCopy.showsMark(.server, onPhone: 1, total: 3))
        #expect(OfflinePageCopy.songsOnThisPhone == "Also on this phone")
        #expect(OfflinePageCopy.serverRowMenus(.server, offline: false))
        #expect(!OfflinePageCopy.serverRowMenus(.phoneCopy, offline: false), "the phone's copy: like offline")
        #expect(!OfflinePageCopy.serverRowMenus(.phone, offline: true))
        #expect(OfflinePageCopy.tryAgain == "Try again")
        // Fix round 2 (m5): a row's swipes on the phone's pages (and the phone's copy) carry no Favourite or Add to
        // playlist; the rest stay.
        #expect(SongSwipe.action(.favourite, serverActions: false) == SwipeAction.none)
        #expect(SongSwipe.action(.addToPlaylist, serverActions: false) == SwipeAction.none)
        #expect(SongSwipe.action(.playNext, serverActions: false) == .playNext)
        #expect(SongSwipe.action(.addToQueue, serverActions: false) == .addToQueue)
        #expect(SongSwipe.action(.favourite, serverActions: true) == .favourite)
    }
}
