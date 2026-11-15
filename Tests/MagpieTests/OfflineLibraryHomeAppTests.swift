import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import os
import Testing
@testable import Magpie

/// Round 28 O3 (owner, 2026-11-15, item 1: "This should work for artists, albums, songs, playlists, flows, etc. In
/// offline mode, only downloaded songs are visible"): Library and Home keep their rows offline, each listing only what's
/// on the phone; flows open offline and download to the phone (D340, D343). Against the stub Aurral and a small Navidrome
/// (never the owner's).
@MainActor @Suite(.serialized) final class OfflineLibraryHomeAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineLibraryHomeAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "OfflineLibraryHomeAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = FailableD1Routing()
    let aurralStore = MemoryAurralStore()
    let network = FakeNetwork(.wifi)
    var aurral: StubAurral { transport.inner.aurral }
    var nav: D1Navidrome { transport.inner.navidrome }

    deinit {
        transport.inner.releaseStatus()
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    static let server = URL(string: "http://192.168.1.2:4533")!

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                 aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                 probeTransport: transport, engine: FakeEngine(), defaults: defaults, systemNowPlaying: false,
                 notifications: false, network: network, audioFetcher: FakeFetcher())
    }

    /// Discover Weekly (Lullaby with a library copy, Unknown Song without, one main-library song) and Road trip, an
    /// ordinary playlist.
    func signedIn(aurralSetUp: Bool = true) async throws -> AppModel {
        nav.add(.init(id: "a-lullaby", title: "Lullaby", artist: "Low", duration: 251, mbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3", library: 2))
        nav.add(.init(id: "m-lullaby", title: "Lullaby", artist: "Low", duration: 252, mbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3", library: 1))
        nav.add(.init(id: "a-unknown", title: "Unknown Song", artist: "Nobody", duration: 180, mbid: nil, library: 2))
        nav.add(.init(id: "m-ref1", title: "Ref One", artist: "Q", duration: 100, mbid: nil, library: 1))
        nav.add(.init(id: "m-ref2", title: "Ref Two", artist: "Q", duration: 100, mbid: nil, library: 1))
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "a-unknown", "m-ref1"])
        nav.setList("pl-road", "Road trip", ["m-ref1", "m-ref2"])
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly")])
        aurral.setJobs([
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", trackMbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3",
                  durationMs: 251_000),
            .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000),
        ])
        let model = makeModel()
        try await model.signIn(urls: [Self.server], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if aurralSetUp {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        await model.scopeIndexRefresh?.value
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        return model
    }

    static func song(_ id: String, title: String? = nil, artist: String = "Q", artistId: String = "ar-q") -> Song {
        Song(id: id, title: title ?? "T \(id)", artist: artist, artistId: artistId, album: "A \(id)", albumId: "al-\(id)",
             duration: 100)
    }

    func download(_ model: AppModel, _ ids: [String]) async {
        model.download(ids.map { Self.song($0) }, reason: .song)
        await model.downloads!.settled()
    }

    func page(_ model: AppModel) async throws -> DiscoverPage {
        _ = try await model.discoverPlaylists()
        return try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
    }

    func manualOffline(_ model: AppModel) { model.updatePreferences { $0.downloads.offlineMode = .on } }

    // MARK: - Flows (D343)

    @Test func flow_downloadToPhoneUsesLibraryCopies() async throws {
        let model = try await signedIn()
        let page = try await page(model)
        #expect(DiscoverPlaylistView.showsDownloadToPhone(model))
        DiscoverPlaylistView.downloadToPhone(model, page)
        await model.downloads!.settled()
        #expect(model.downloads!.localFiles.keys.sorted() == ["a-unknown", "m-lullaby", "m-ref1"],
                "Lullaby's library copy, not Aurral's")
        let saved = await model.downloads!.store.playlists().first { $0.id == "pl-dw" }
        #expect(saved?.kind == .flow && saved?.copies?["a-lullaby"] == "m-lullaby", "its original→copy map is kept (O2)")
        #expect(model.downloadStatus(page.songs.map(\.id), reason: .playlist("pl-dw")) == .downloaded,
                "today's mark and Remove download follow")
        #expect(OfflinePageCopy.downloadFlowLabel == "Download" && OfflinePageCopy.downloadFlowHint == "Downloads this flow to this phone")
    }

    @Test func flow_downloadHiddenOffline() async throws {
        let model = try await signedIn()
        let page = try await page(model)
        manualOffline(model)
        #expect(!DiscoverPlaylistView.showsDownloadToPhone(model))
        DiscoverPlaylistView.downloadToPhone(model, page)   // refused: nothing queued
        await model.downloads!.settled()
        #expect(model.downloads!.localFiles.isEmpty && model.downloadStatus(page.songs.map(\.id), reason: .playlist("pl-dw")) == .none)
    }

    @Test func flow_offlineOpensFromThePhone() async throws {
        let model = try await signedIn()
        _ = try await page(model)
        await download(model, ["m-lullaby"])
        manualOffline(model)
        #expect(!PlaylistRouteView.opensDiscoverPage(offline: model.isOffline, isDiscover: model.isDiscoverPlaylist(id: "pl-dw")))
        var outcome: PlaylistView.Outcome?
        await PlaylistView.load(model, playlistId: "pl-dw", fromPhone: false) { outcome = $0 }
        guard case .shown(let shown)? = outcome else { Issue.record("the flow didn't open offline"); return }
        #expect(shown.source == .phone && shown.kind == .flow)
        #expect(shown.songs.map(\.id) == ["m-lullaby"] && shown.onPhone == 1 && shown.total == 3)
    }

    @Test func flow_offlineHidesAurralActions() async throws {
        let model = try await signedIn()
        _ = try await page(model)
        await download(model, ["m-ref1"])
        manualOffline(model)
        // The phone's page: no Refresh Flow, Delete, Search again, Download songs, Edit or Artists in this playlist (it's
        // the playlist page, not Discover's), no editing, and its ⋯ holds only Add to queue.
        #expect(!PlaylistRouteView.opensDiscoverPage(offline: true, isDiscover: true))
        #expect(PlaylistMoreMenu.items(editable: true, onServer: false, offline: true) == [.addToQueue])
        #expect(!PlaylistView.isEditable(canEdit: true, fromPhone: false, source: .phone))
        #expect(PlaylistRouteView.opensDiscoverPage(offline: false, isDiscover: true), "online, Discover's own page")
    }

    // MARK: - Library (D340)

    @Test func library_offlineListsComeFromThePhone() async throws {
        let model = try await signedIn()
        _ = try await page(model)
        await download(model, ["m-ref1"])
        await PlaylistView.load(model, playlistId: "pl-road", fromPhone: false) { _ in }   // recorded (Q3)
        #expect(await eventually { await model.downloads!.store.records().playlists["pl-road"] != nil })
        manualOffline(model)
        #expect(model.libraryRows == [.playlists, .artists, .albums, .songs, .genres, .downloads, .discover])
        #expect(await OfflineLists.playlists(model).map(\.id) == ["pl-road"], "recorded playlists, not flows (D185)")
        #expect(await OfflineLists.albums(model).map(\.id) == ["al-m-ref1"])
        #expect(await OfflineLists.songs(model).map(\.id) == ["m-ref1"])
        // (Reading Road trip online refreshed the song's details from the server, so its artist's id is the server's.)
        let artists = await OfflineLists.artists(model, albumArtistsOnly: false)
        #expect(artists.map(\.name) == ["Q"])
        #expect(await OfflineLists.artists(model, albumArtistsOnly: true).map(\.id) == artists.map(\.id),
                "Q is the album artist of the album on the phone")
        #expect(await DiscoverListView.offlineFlows(model).map(\.id) == ["pl-dw"])
        // Nothing asked of the server for any of it.
        let before = nav.state.withLock { ($0.getPlaylists, $0.getPlaylist.count) }
        _ = await OfflineLists.playlists(model)
        _ = await OfflineLists.albums(model)
        #expect(nav.state.withLock { ($0.getPlaylists, $0.getPlaylist.count) } == before)
    }

    @Test func library_offlineDiscoverOnlyWithAurral() async throws {
        let model = try await signedIn(aurralSetUp: false)
        await download(model, ["m-ref1"])
        manualOffline(model)
        #expect(!model.libraryRows.contains(.discover))
        #expect(await DiscoverListView.offlineFlows(model).isEmpty)
        #expect(!model.homeSections.contains(.discover))
    }

    // MARK: - Home (D340)

    @Test func home_offlineQuickGridOnlyOnPhone() async throws {
        let model = try await signedIn()
        _ = try await page(model)
        await download(model, ["m-ref1"])
        let onPhone = Album(id: "al-m-ref1", name: "A m-ref1", artist: "Q", songCount: 1, duration: 100)
        let gone = Album(id: "al-gone", name: "Gone", artist: "Q", songCount: 1, duration: 100)
        model.noteRecentlyPlayed(.album(gone, at: .now))
        model.noteRecentlyPlayed(.playlist(Playlist(id: "pl-dw", name: "Discover Weekly", songCount: 3, duration: 1), at: .now))
        model.noteRecentlyPlayed(.album(onPhone, at: .now))
        manualOffline(model)
        let ids = await model.offlineQuickIds()
        let tiles = model.quickAccessTiles(recentAlbums: [gone], onPhone: ids)
        #expect(tiles.map(\.id) == ["album-al-m-ref1", "playlist-pl-dw"], "only what opens on the phone (a flow too)")
        #expect(model.quickAccessTiles(recentAlbums: [], onPhone: nil).count == 3, "online: everything, as before")
    }

    @Test func home_offlineFlowsAndPlaylistsShelves() async throws {
        let model = try await signedIn()
        _ = try await page(model)
        await download(model, ["m-ref1"])
        await PlaylistView.load(model, playlistId: "pl-road", fromPhone: false) { _ in }
        #expect(await eventually { await model.downloads!.store.records().playlists["pl-road"] != nil })
        manualOffline(model)
        #expect(model.homeSections == [.greeting, .quickAccess, .discover, .downloaded, .playlists])
        let shelves = try await model.homeShelves(for: model.homeSections)
        let byId = Dictionary(uniqueKeysWithValues: shelves.map { ($0.section, $0.items.map(\.id)) })
        #expect(byId[.discover] == ["playlist-pl-dw"], "Your flows: the flows on the phone")
        #expect(byId[.playlists] == ["playlist-pl-road"], "Playlists: on the phone (recorded, Q3)")
        #expect(byId[.downloaded] == ["album-al-m-ref1"])
        #expect(byId[.quickAccess] == nil, "the server's recently played isn't asked offline")
    }

    // MARK: - Fix round 1

    /// I3 / design H4: offline, a playlist's long press (Home's tiles, Library's rows) queues the songs on the phone, for a
    /// recorded playlist and a flow too.
    @Test func queue_recordedPlaylistAndFlowQueueThePhonesSongs() async throws {
        let model = try await signedIn()
        _ = try await page(model)
        await download(model, ["m-ref1"])
        await PlaylistView.load(model, playlistId: "pl-road", fromPhone: false) { _ in }
        #expect(await eventually { await model.downloads!.store.records().playlists["pl-road"] != nil })
        manualOffline(model)
        #expect(try await model.songs(of: .playlist("pl-road")).map(\.id) == ["m-ref1"], "recorded (Q3)")
        #expect(try await model.songs(of: .playlist("pl-dw")).map(\.id) == ["m-ref1"], "a flow on the phone")
        await model.queue(.playlist("pl-road"), .end, shuffled: false)
        #expect(model.player.queue.current?.song.id == "m-ref1" || model.player.queue.upcoming.contains { $0.song.id == "m-ref1" })
    }

    /// M2: a Discover playlist read through the playlist page is never recorded as an ordinary playlist.
    @Test func records_neverAFlowAsAPlaylist() async throws {
        let model = try await signedIn()
        _ = try await page(model)
        await download(model, ["m-ref1"])
        #expect(model.isDiscoverPlaylist(id: "pl-dw"))
        await PlaylistView.load(model, playlistId: "pl-dw", fromPhone: false) { _ in }
        await PlaylistView.load(model, playlistId: "pl-road", fromPhone: false) { _ in }
        #expect(await eventually { await model.downloads!.store.records().playlists["pl-road"] != nil })
        #expect(await model.downloads!.store.records().playlists["pl-dw"] == nil)
    }

    /// M6: Library › Discover offline says how many of each flow's songs are here.
    @Test func discover_offlineRowsCountSongsOnThePhone() async throws {
        let model = try await signedIn()
        _ = try await page(model)
        await download(model, ["m-ref1"])
        manualOffline(model)
        let rows = await DiscoverListView.offlineRows(model)
        #expect(rows.map(\.playlist.id) == ["pl-dw"])
        #expect(rows.first.flatMap { OfflinePageCopy.onPhone($0.onPhone, of: $0.total) } == "1 of 3 songs on this phone")
    }

    /// M3: a flow's page whose read fails shows the phone's copy (from the saved file).
    @Test func flow_phoneCopyWhenTheReadFails() async throws {
        let model = try await signedIn()
        _ = try await page(model)
        await download(model, ["m-ref1"])
        let copy = await DiscoverPlaylistView.phoneCopy(model, playlistId: "pl-dw", failed: true)
        #expect(copy?.songs.map(\.id) == ["m-ref1"])
        #expect(await DiscoverPlaylistView.phoneCopy(model, playlistId: "pl-dw", failed: false) == nil)
    }

    /// Design H3: "Nothing downloaded yet" only when nothing is; otherwise each list says what it lacks.
    @Test func emptyLists_sayWhatTheyLack() {
        #expect(OfflineLists.empty(.playlists, phoneEmpty: true).title == "Nothing downloaded yet")
        #expect(OfflineLists.empty(.playlists, phoneEmpty: false).title == "No playlists on this phone")
        #expect(OfflineLists.empty(.playlists, phoneEmpty: false).detail == "Download a playlist and it plays here without a connection.")
        #expect(OfflineLists.empty(.flows, phoneEmpty: false).title == "No flows on this phone")
        #expect(OfflineLists.empty(.albumArtists, phoneEmpty: false).title
                == "No album artists on this phone. Turn off Album artists only to see everyone.")
        #expect(PlaylistShow.all.footer(offline: true) == "Playlists with songs on this phone.")
        #expect(PlaylistShow.all.footer(offline: false) == PlaylistShow.all.footer)
        #expect(PlaylistShow.yours.emptyTitle(offline: true) == "None of your playlists are on this phone")
        #expect(PlaylistShow.all.emptyTitle(offline: true) == "No playlists on this phone")
    }

    /// Design M7 (amends D340): with favourites kept downloaded, Favourites stays offline, listing the favourites on the
    /// phone and asking nothing.
    @Test func favourites_offlineWhenKeptDownloaded() async throws {
        let model = try await signedIn()
        model.updatePreferences { $0.downloads.keepFavourites = true }
        model.download([Self.song("m-ref1")], reason: .favourites)
        await model.downloads!.settled()
        await download(model, ["m-ref2"])
        manualOffline(model)
        #expect(model.libraryRows.contains(.favourites))
        #expect(!model.libraryRows(carPlay: true).contains(.favourites), "the car's Favourites is O4's")
        let before = nav.state.withLock { $0.getPlaylists }
        #expect(try await model.favourites().songs.map(\.id) == ["m-ref1"])
        #expect(nav.state.withLock { $0.getPlaylists } == before)
        model.updatePreferences { $0.downloads.keepFavourites = false }
        #expect(!model.libraryRows.contains(.favourites))
    }

    /// Design M9, H5, M5, H2, M2, M3; review M4: Home, the notice, pull to refresh and the flow's Download.
    @Test func homeNoticeRefreshAndFlowCopy() {
        // M9: Recently downloaded follows its switch unless Home would otherwise be empty.
        let sections: [HomeSection] = [.greeting, .quickAccess, .downloaded, .playlists]
        #expect(HomeView.offlineSections(sections, downloadedOn: false, hasContent: { $0 == .playlists })
                == [.greeting, .quickAccess, .playlists])
        #expect(HomeView.offlineSections(sections, downloadedOn: false, hasContent: { $0 == .downloaded })
                == sections, "nothing else to show: it shows")
        #expect(HomeView.offlineSections(sections, downloadedOn: true, hasContent: { _ in true }) == sections)
        // Review M4: the quick grid reads again as plays are noted.
        #expect(HomeView.quickKey(pageKey: "offline|1|0", plays: 2) != HomeView.quickKey(pageKey: "offline|1|0", plays: 3))
        // H5: at accessibility sizes the notice scrolls with the page.
        #expect(OfflineNoticeInset.pinned(accessibility: false) && !OfflineNoticeInset.pinned(accessibility: true))
        // M5: in Offline mode pull to refresh reads the phone again and says so; by itself it tries the library.
        #expect(OfflineRefresh.action(.manual) == .rereadAndAnnounce)
        #expect(OfflineRefresh.action(.automatic) == .reconnect)
        #expect(OfflineRefresh.action(.online) == .online && OfflineRefresh.action(.suspect) == .online)
        // H2: Aurral's own download says what it does.
        #expect(DiscoverPagesCopy.downloadSongs == "Add these songs to your library")
        #expect(DiscoverPagesCopy.downloadSongsSymbol == "plus.circle")
        // M2, M3: the flow's Download.
        #expect(OfflinePageCopy.flowAbout(12) == "About 12 songs" && OfflinePageCopy.flowAbout(1) == "About 1 song")
        #expect(OfflinePageCopy.flowFollows == "New songs download when this flow changes")
        #expect(OfflinePageCopy.downloadFlowHint == "Downloads this flow to this phone")
    }
}
