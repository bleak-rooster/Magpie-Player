import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import os
import Testing
@testable import Magpie

/// Every request that reaches the stubs (after the offline gate), by path.
final class RecordingD1Transport: HTTPTransport, @unchecked Sendable {
    let inner = FailableD1Routing()
    private let sent = OSAllocatedUnfairLock(initialState: [String]())
    var paths: [String] { sent.withLock { $0 } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.withLock { $0.append(request.url?.path ?? "") }
        return try await inner.send(request)
    }
}

/// Round 28 O3 (owner, 2026-11-15, item 1: "Ensure this works in all possible configurations and there are no edge case
/// errors in how it works"; plan §7.2, D345): the phone half of the 24-cell matrix: the four setups (Navidrome alone;
/// + Lidarr; + Aurral; all, with ListenBrainz) × online, offline by itself and Offline mode. Each cell checks that offline
/// only downloaded songs are listed, every control shown works or says why, Offline mode sends nothing and offline by
/// itself only the check (ping and login), and the rows each setup shows. The car half is O4's. Against the stub Aurral,
/// a small Navidrome and a Lidarr address nothing answers for (never the owner's).
@MainActor @Suite(.serialized) final class OfflineMatrixAppTests {
    enum Setup: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case navidrome, lidarr, aurral, all
        var hasLidarr: Bool { self == .lidarr || self == .all }
        var hasAurral: Bool { self == .aurral || self == .all }
        var testDescription: String { rawValue }
    }

    enum State: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case online, automatic, manual
        var testDescription: String { rawValue }
    }

    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineMatrixAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "OfflineMatrixAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = RecordingD1Transport()
    let aurralStore = MemoryAurralStore()
    let lidarrStore = MemoryLidarrStore()
    var aurral: StubAurral { transport.inner.inner.aurral }
    var nav: D1Navidrome { transport.inner.inner.navidrome }

    deinit {
        transport.inner.inner.releaseStatus()
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    static func song(_ id: String) -> Song {
        Song(id: id, title: "Ref \(id)", artist: "Q", artistId: "ar-q", album: "A \(id)", albumId: "al-\(id)", duration: 100)
    }

    /// Signed in to the setup, with Ref One downloaded, Road trip read (recorded, Q3) and, with Aurral, Discover Weekly's
    /// page opened (saved, D283).
    func signedIn(_ setup: Setup) async throws -> AppModel {
        nav.add(.init(id: "a-lullaby", title: "Lullaby", artist: "Low", duration: 251, mbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3", library: 2))
        nav.add(.init(id: "m-lullaby", title: "Lullaby", artist: "Low", duration: 252, mbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3", library: 1))
        nav.add(.init(id: "a-unknown", title: "Unknown Song", artist: "Nobody", duration: 180, mbid: nil, library: 2))
        nav.add(.init(id: "m-ref1", title: "Ref m-ref1", artist: "Q", duration: 100, mbid: nil, library: 1))
        nav.add(.init(id: "m-ref2", title: "Ref m-ref2", artist: "Q", duration: 100, mbid: nil, library: 1))
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "a-unknown", "m-ref1"])
        nav.setList("pl-road", "Road trip", ["m-ref1", "m-ref2"])
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly")])
        aurral.setJobs([
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", trackMbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3",
                  durationMs: 251_000),
            .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000),
        ])
        if setup.hasLidarr {
            try lidarrStore.save(LidarrConnection(base: URL(string: "http://127.0.0.1:8686")!, apiKey: "test-key"))
        }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults, systemNowPlaying: false,
                             notifications: false, network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if setup.hasAurral {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        if setup == .all { model.hasListenBrainzToken = true }
        await model.scopeIndexRefresh?.value
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        model.download([Self.song("m-ref1")], reason: .song)
        await model.downloads!.settled()
        await PlaylistView.load(model, playlistId: "pl-road", fromPhone: false) { _ in }
        #expect(await eventually { await model.downloads!.store.records().playlists["pl-road"] != nil })
        if setup.hasAurral {
            _ = try await model.discoverPlaylists()
            _ = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
            #expect(await eventually { await model.offlineFlowPage(id: "pl-dw") != nil }, "the page saved (D283)")
        }
        #expect((model.lidarr != nil) == setup.hasLidarr && model.aurralSetUp == setup.hasAurral)
        return model
    }

    func enter(_ state: State, _ model: AppModel) {
        switch state {
        case .online: break
        case .automatic: model.serverReachable = false   // as O2's tests do: the library out of reach
        case .manual: model.updatePreferences { $0.downloads.offlineMode = .on }
        }
    }

    @Test(arguments: Setup.allCases, State.allCases)
    func matrix_phone_noDeadButtons(_ setup: Setup, _ state: State) async throws {
        let model = try await signedIn(setup)
        enter(state, model)
        if state == .online {
            try await online(setup, model)
        } else {
            try await offline(setup, state, model)
        }
    }

    /// Online: today's rows and controls in each setup.
    func online(_ setup: Setup, _ model: AppModel) async throws {
        #expect(!model.isOffline && OfflineNotice.variant(for: model) == nil)
        let rows = model.libraryRows
        #expect(rows.contains(.favourites) && rows.contains(.discover) == setup.hasAurral && rows.contains(.requests) == setup.hasLidarr)
        let home = model.homeSections
        #expect(home.contains(.jumpBackIn) && home.contains(.madeForYou) == (setup == .all)
                && home.contains(.discover) == setup.hasAurral)
        #expect(model.tryAvailability != .offline)
        #expect(DiscoverPlaylistView.showsDownloadToPhone(model))
        #expect(PlaylistRouteView.opensDiscoverPage(offline: false, isDiscover: model.isDiscoverPlaylist(id: "pl-dw")) == setup.hasAurral)
    }

    /// Offline (by itself or Offline mode): only what's on the phone, every control works or says why, and nothing sent
    /// (Offline mode) or only the check (by itself).
    func offline(_ setup: Setup, _ state: State, _ model: AppModel) async throws {
        #expect(model.isOffline && model.offlineState == (state == .manual ? .manual : .automatic))
        let sentBefore = transport.paths.count

        // (4) The rows.
        #expect(model.libraryRows == [.playlists, .artists, .albums, .songs, .genres, .downloads] + (setup.hasAurral ? [.discover] : []))
        #expect(model.homeSections == [.greeting, .quickAccess] + (setup.hasAurral ? [.discover] : []) + [.downloaded, .playlists])
        #expect(!model.showsRecentlyAddedGrid)

        // (1) Only downloaded songs are listed: lists, search, pages, shelves, flows.
        #expect(await OfflineLists.songs(model).map(\.id) == ["m-ref1"])
        #expect(await OfflineLists.albums(model).map(\.id) == ["al-m-ref1"])
        #expect(await OfflineLists.playlists(model).map(\.id) == ["pl-road"])
        #expect(await model.offlineCatalog.search("Ref").songs.map(\.id) == ["m-ref1"], "Search: downloads only (Q2)")
        var album: AlbumView.Outcome?
        await AlbumView.load(model, albumId: "al-m-ref1") { album = $0 }
        guard case .shown(let shownAlbum)? = album else { Issue.record("album didn't open offline"); return }
        #expect(shownAlbum.source == .phone && shownAlbum.album.songs?.map(\.id) == ["m-ref1"])
        var playlist: PlaylistView.Outcome?
        await PlaylistView.load(model, playlistId: "pl-road", fromPhone: false) { playlist = $0 }
        guard case .shown(let road)? = playlist else { Issue.record("playlist didn't open offline"); return }
        #expect(road.songs.map(\.id) == ["m-ref1"] && road.onPhone == 1 && road.total == 2)
        var flow: PlaylistView.Outcome?
        await PlaylistView.load(model, playlistId: "pl-dw", fromPhone: false) { flow = $0 }
        if setup.hasAurral {
            guard case .shown(let dw)? = flow else { Issue.record("flow didn't open offline"); return }
            #expect(dw.kind == .flow && dw.songs.map(\.id) == ["m-ref1"])
        } else {
            guard case .notOnPhone? = flow else { Issue.record("no flows without Aurral"); return }
        }
        #expect(await DiscoverListView.offlineFlows(model).map(\.id) == (setup.hasAurral ? ["pl-dw"] : []))
        let shelves = try await model.homeShelves(for: model.homeSections)
        let byId = Dictionary(uniqueKeysWithValues: shelves.map { ($0.section, $0.items.map(\.id)) })
        #expect(byId[.playlists] == ["playlist-pl-road"] && byId[.downloaded] == ["album-al-m-ref1"])
        #expect(byId[.discover] == (setup.hasAurral ? ["playlist-pl-dw"] : nil))

        // (2) Every control shown works or says why.
        let notice = try #require(OfflineNotice.variant(for: model))
        #expect(notice.action == (state == .manual ? .goOnline : .tryAgain), "the notice offers the way back")
        #expect(model.tryAvailability.message == AppModel.offlineCopy, "Try, Add, Keep, Not for me, Bring in more say why (D139)")
        #expect(!AlbumView.showsServerActions(shownAlbum.source, offline: true, id: shownAlbum.album.id))
        #expect(!model.automixAvailable(artistId: "ar-q", albums: []), "Automix hidden (D305)")
        #expect(!DiscoverPlaylistView.showsDownloadToPhone(model))
        #expect(!PlaylistRouteView.opensDiscoverPage(offline: true, isDiscover: true), "no Aurral actions offline")
        #expect(PlaylistMoreMenu.items(editable: true, onServer: road.source == .server, offline: true) == [.addToQueue])
        await model.setFavourite(.song("m-ref1"), true)
        #expect(model.libraryEdits.notice?.text == AppModel.offlineCopy && !model.isFavourite(.song("m-ref1")),
                "the star refuses with You're offline")
        #expect(QueueView.skippedOffline("m-ref2", offline: true, onPhone: { model.downloads?.localFiles[$0] != nil }))
        #expect(!QueueView.skippedOffline("m-ref1", offline: true, onPhone: { model.downloads?.localFiles[$0] != nil }))

        // (3) Offline mode sends nothing; offline by itself only the check (ping, then its login).
        let sent = Array(transport.paths.dropFirst(sentBefore))
        if state == .manual {
            #expect(sent.isEmpty, "Offline mode sent \(sent)")
        } else {
            #expect(sent.allSatisfy { $0.hasSuffix("/rest/ping") || $0.hasSuffix("/auth/login") }, "sent \(sent)")
        }
    }
}
