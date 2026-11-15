import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import os
import Testing
@testable import Magpie

/// Round 28 O2 (owner, 2026-11-15, item 1: "This should work for artists, albums, songs, playlists, flows, etc."; Q4):
/// flows on the phone offline from round 27's saved Discover file, read-only, with D185/D189/D190 as saved; a downloaded
/// flow keeps in step with its flow when online; and the catalogue's records in all four setups (D331–D335). Against the
/// stub Aurral and a small Navidrome (never the owner's).
@MainActor @Suite(.serialized) final class OfflineFlowsAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineFlowsAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "OfflineFlowsAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = FailableD1Routing()
    let fetcher = FakeFetcher()
    let aurralStore = MemoryAurralStore()
    let lidarrStore = MemoryLidarrStore()
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
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                 aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                 probeTransport: transport, engine: FakeEngine(), defaults: defaults, systemNowPlaying: false,
                 notifications: false, network: network, audioFetcher: fetcher)
    }

    /// Discover Weekly (the user's flow: Lullaby with a library copy, Unknown Song without, one main-library song) and,
    /// with `sams`, Sam's flow "Sam Mix".
    func signedIn(sams: Bool = false, aurralSetUp: Bool = true, lidarr: Bool = false) async throws -> AppModel {
        nav.add(.init(id: "a-lullaby", title: "Lullaby", artist: "Low", duration: 251, mbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3", library: 2))
        nav.add(.init(id: "m-lullaby", title: "Lullaby", artist: "Low", duration: 252, mbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3", library: 1))
        nav.add(.init(id: "a-unknown", title: "Unknown Song", artist: "Nobody", duration: 180, mbid: nil, library: 2))
        nav.add(.init(id: "m-ref1", title: "Ref One", artist: "Q", duration: 100, mbid: nil, library: 1))
        nav.add(.init(id: "m-ref2", title: "Ref Two", artist: "Q", duration: 100, mbid: nil, library: 1))
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "a-unknown", "m-ref1"])
        var flows: [StubAurral.Flow] = [.init(id: "flow-dw", name: "Discover Weekly")]
        var jobs: [StubAurral.Job] = [
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", trackMbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3",
                  durationMs: 251_000),
            .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000),
        ]
        if sams {
            aurral.addUser(id: 2, username: "sam", password: "sam-pw")
            nav.add(.init(id: "a-sam1", title: "Sam One", artist: "S", duration: 120, mbid: nil, library: 2))
            nav.setList("pl-sam", "Sam Mix", ["a-sam1"])
            flows.append(.init(id: "flow-sam", name: "Sam Mix", ownerUserId: 2))
            jobs.append(.init(flowId: "flow-sam", artistName: "S", trackName: "Sam One", durationMs: 120_000))
        }
        aurral.setFlows(flows)
        aurral.setJobs(jobs)
        if lidarr { try lidarrStore.save(LidarrConnection(base: URL(string: "http://127.0.0.1:8686")!, apiKey: "test-key")) }
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

    /// Discover read and each flow's page opened, so the saved file holds them (D283).
    func openPages(_ model: AppModel, _ ids: [String]) async throws {
        _ = try await model.discoverPlaylists()
        for id in ids { _ = try await model.openDiscoverPage(playlistId: id, fresh: false, waitForRead: false) { _ in } }
    }

    static func song(_ id: String, title: String = "T") -> Song {
        Song(id: id, title: title, artist: "Q", album: "A", albumId: "al-\(id)", duration: 100)
    }

    func download(_ model: AppModel, _ ids: [String]) async {
        model.download(ids.map { Self.song($0) }, reason: .song)
        await model.downloads!.settled()
    }

    func file(_ model: AppModel) throws -> URL {
        DiscoverSnapshotFile(root: tmp, scope: try #require(model.aurralFeedsScope)).url
    }

    // MARK: - Flows offline (D335)

    @Test func flows_offlineFromSavedFileOnlyWithADownload() async throws {
        let model = try await signedIn(sams: true)
        model.showEveryonesFlows = true
        try await openPages(model, ["pl-dw", "pl-sam"])
        await download(model, ["m-lullaby"])   // Lullaby's library copy
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await model.offlineFlows().map(\.id) == ["pl-dw"], "Sam Mix holds nothing on the phone")
        let page = try #require(await model.offlineFlowPage(id: "pl-dw"))
        #expect(page.songs.map(\.id) == ["m-lullaby"] && page.total == 3 && page.kind == .flow)
        #expect(await model.offlineFlowPage(id: "pl-sam") == nil)
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        await download(model, ["m-ref1", "a-sam1"])
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await model.offlineFlowPage(id: "pl-dw")?.songs.map(\.id) == ["m-lullaby", "m-ref1"], "in the flow's order")
        #expect(Set(await model.offlineFlows().map(\.id)) == ["pl-dw", "pl-sam"])
    }

    @Test func flows_offlineRespectsEveryoneSwitch() async throws {
        let model = try await signedIn(sams: true)
        model.showEveryonesFlows = true
        try await openPages(model, ["pl-dw", "pl-sam"])
        await download(model, ["m-ref1", "a-sam1"])
        model.showEveryonesFlows = false
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await model.offlineFlows().map(\.id) == ["pl-dw"], "only mine (D189)")
        model.showEveryonesFlows = true
        let flows = await model.offlineFlows()
        #expect(Set(flows.map(\.id)) == ["pl-dw", "pl-sam"], "everyone's (D190)")
        #expect(flows.first { $0.id == "pl-sam" }?.owner == "sam", "D205's caption, from the saved owner")
        #expect(flows.first { $0.id == "pl-dw" }.map { OwnerCaption.text(owner: $0.owner, signedInUser: StubAurral.defaultUsername) } == .some(nil))
        // D185: a downloaded flow stays out of the phone's Playlists list.
        let catalog = await model.offlineCatalog
        #expect(!catalog.playlists(includingRecorded: true).contains { $0.id == "pl-dw" || $0.id == "pl-sam" })
    }

    @Test func flows_noneWithoutAurral() async throws {
        let model = try await signedIn(aurralSetUp: false)
        await download(model, ["m-ref1"])
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await model.offlineFlows().isEmpty)
        #expect(await model.offlineFlowPage(id: "pl-dw") == nil)
    }

    @Test func flows_savedFileNeverWrittenOffline() async throws {
        let model = try await signedIn()
        try await openPages(model, ["pl-dw"])
        await download(model, ["m-ref1"])
        let url = try file(model)
        let before = try Data(contentsOf: url)
        let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        model.updatePreferences { $0.downloads.offlineMode = .on }
        _ = await model.offlineFlows()
        _ = await model.offlineFlowPage(id: "pl-dw")
        if let page = model.savedDiscoverPage(playlistId: "pl-dw") { model.followDownloadedFlow(page) }
        #expect(try Data(contentsOf: url) == before)
        #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
    }

    // MARK: - A downloaded flow keeps in step (Q4)

    @Test func flows_downloadedFlowFollowsItsRefresh() async throws {
        let model = try await signedIn()
        let page = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        let songs = page.entries.map(\.song)
        #expect(songs.map(\.id) == ["m-lullaby", "a-unknown", "m-ref1"], "library copies where found")
        try await downloadFlow(model, page)
        await download(model, ["m-ref1"])   // also downloaded on its own
        #expect(model.downloads!.localFiles.keys.sorted() == ["a-unknown", "m-lullaby", "m-ref1"])

        // Offline, the follow does nothing.
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "m-ref2"], changed: "2026-11-08T10:00:00Z")
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.followDownloadedFlow(DiscoverPage(playlist: page.playlist, flow: page.flow,
                                                      entries: [DiscoverEntry(song: Self.song("m-ref2"), original: Self.song("m-ref2"))]))
        await model.downloads!.settled()
        #expect(model.downloads!.localFiles.keys.sorted() == ["a-unknown", "m-lullaby", "m-ref1"])

        // Online on mobile data (not allowed for downloads): the songs that left go, the new one waits for Wi-Fi.
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        network.status = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)
        _ = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        #expect(await eventually {
            await model.downloads!.settled()
            return model.downloads!.localFiles.keys.sorted() == ["m-lullaby", "m-ref1"]
        }, "a-unknown left; m-ref1 left the flow but is kept for itself (task M9)")
        #expect(model.downloads!.localFiles["m-ref2"] == nil, "the new song waits for Wi-Fi (task M9)")
        #expect(model.downloads!.reasons(for: "m-ref1") == [.song])
        network.status = .wifi
        #expect(await eventually {
            await model.downloads!.settled()
            return model.downloads!.localFiles.keys.sorted() == ["m-lullaby", "m-ref1", "m-ref2"]
        })
        let saved = await model.downloads!.store.playlists().first { $0.id == "pl-dw" }
        #expect(saved?.songIds == ["m-lullaby", "m-ref2"] && saved?.kind == .flow, "the flow stays a flow")
        #expect(saved?.owner == nil, "the flow's own owner isn't replaced by the library's (task M6)")
    }

    /// The flow downloaded as a whole, as O3's Download does (library copies where found).
    func downloadFlow(_ model: AppModel, _ page: DiscoverPage) async throws {
        model.downloadFlowToPhone(page)
        await model.downloads!.settled()
    }

    func streamed(_ id: String) -> Bool {
        fetcher.urls.contains { $0.path.hasSuffix("/rest/stream") && $0.query?.contains("id=\(id)") == true }
    }

    // MARK: - Fix round 2

    /// SN1 + N2: lookups that fail (on a page read again, twice, and on pull to refresh) never drop the library copy on
    /// the phone, never fetch Aurral's copy in its place, never change the downloaded flow's songs, and are never kept.
    @Test func flows_lookupErrorsNeverDropTheCopyOnThePhone() async throws {
        let model = try await signedIn()
        let page = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        try await downloadFlow(model, page)
        let before = await model.downloads!.store.playlists().first { $0.id == "pl-dw" }?.songIds
        #expect(before == ["m-lullaby", "a-unknown", "m-ref1"])
        transport.failLookups = true
        model.discover.lookups = [:]   // nothing known: every song is looked up again
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "a-unknown", "m-ref1"], changed: "2026-11-10T10:00:00Z")
        for fresh in [false, false, true] {
            _ = try? await model.openDiscoverPage(playlistId: "pl-dw", fresh: fresh, waitForRead: false) { _ in }
            await model.downloads!.settled()
            #expect(model.downloads!.localFiles["m-lullaby"] != nil, "fresh \(fresh): the library copy stays")
            #expect(!streamed("a-lullaby"), "fresh \(fresh): Aurral's copy is never fetched")
            #expect(await model.downloads!.store.playlists().first { $0.id == "pl-dw" }?.songIds == before)
            #expect(model.discover.lookups["a-lullaby"].map { $0.copy?.id == "m-lullaby" } ?? true,
                    "fresh \(fresh): an errored lookup is never kept as \"no copy\"")
        }
        // Even a page treated as complete whose Lullaby shows as Aurral's keeps the copy the flow has (the map).
        let originals = DiscoverPage(playlist: page.playlist, flow: page.flow, entries: page.entries.map {
            DiscoverEntry(song: $0.original, original: $0.original)
        })
        model.followDownloadedFlow(originals, complete: true)
        await model.downloads!.settled()
        #expect(model.downloads!.localFiles["m-lullaby"] != nil && !streamed("a-lullaby"))
        #expect(await model.downloads!.store.playlists().first { $0.id == "pl-dw" }?.songIds == before)
    }

    /// SN1: a song whose original really left the flow still leaves (unless something else keeps it).
    @Test func flows_songThatLeftStillLeaves() async throws {
        let model = try await signedIn()
        let page = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        try await downloadFlow(model, page)
        await download(model, ["m-ref1"])
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby"], changed: "2026-11-11T10:00:00Z")
        _ = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        await model.downloads!.settled()
        #expect(model.downloads!.localFiles.keys.sorted() == ["m-lullaby", "m-ref1"], "a-unknown left; m-ref1 kept for itself")
        let saved = await model.downloads!.store.playlists().first { $0.id == "pl-dw" }
        #expect(saved?.songIds == ["m-lullaby"] && saved?.copies == ["a-lullaby": "m-lullaby"])
    }

    /// N1 / SN2: with Aurral removed after the download, the ordinary playlist page still never refreshes the flow.
    @Test func flows_ordinaryPageNeverRefreshesAFlowAfterAurralIsRemoved() async throws {
        let model = try await signedIn()
        let page = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        try await downloadFlow(model, page)
        model.disconnectAurral()
        #expect(!model.aurralSetUp)
        await model.refreshDownloadedPlaylist(page.playlist, songs: page.entries.map(\.original))
        await model.downloads!.settled()
        #expect(model.downloads!.localFiles.keys.sorted() == ["a-unknown", "m-lullaby", "m-ref1"])
        #expect(!streamed("a-lullaby"))
    }

    /// Security M1: a background read whose lookups didn't all finish never swaps a library copy on the phone for
    /// Aurral's.
    @Test func flows_followKeepsDownloadedCopyWhenLookupIncomplete() async throws {
        let model = try await signedIn()
        let page = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        try await downloadFlow(model, page)
        #expect(model.downloads!.localFiles["m-lullaby"] != nil)
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "a-unknown", "m-ref1"], changed: "2026-11-09T10:00:00Z")
        _ = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: true, waitForRead: false, background: true,
                                             budget: DiscoverLookupBudget(0)) { _ in }
        await model.downloads!.settled()
        #expect(model.downloads!.localFiles["m-lullaby"] != nil, "the library copy stays")
        #expect(model.downloads!.localFiles["a-lullaby"] == nil, "Aurral's copy isn't fetched in its place")
        let saved = await model.downloads!.store.playlists().first { $0.id == "pl-dw" }
        #expect(saved?.songIds == ["m-lullaby", "a-unknown", "m-ref1"])
        // A complete read whose lookup for Lullaby found nothing this time still keeps the copy on the phone.
        let incomplete = DiscoverPage(playlist: page.playlist, flow: page.flow, entries: page.entries.map {
            DiscoverEntry(song: $0.original, original: $0.original)
        })
        model.followDownloadedFlow(incomplete)
        await model.downloads!.settled()
        #expect(model.downloads!.localFiles["m-lullaby"] != nil && model.downloads!.localFiles["a-lullaby"] == nil,
                "compared by the original id: the copy already on the phone is kept")
    }

    /// Security M1: the ordinary playlist page's refresh (Aurral's songs, no lookups) never swaps a downloaded flow's
    /// library copies back.
    @Test func flows_playlistViewRefreshDoesNotSwapCopiesBack() async throws {
        let model = try await signedIn()
        let page = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        try await downloadFlow(model, page)
        let raw = page.entries.map(\.original)
        await model.refreshDownloadedPlaylist(page.playlist, songs: raw)
        await model.downloads!.settled()
        #expect(model.downloads!.localFiles.keys.sorted() == ["a-unknown", "m-lullaby", "m-ref1"])
        #expect(await model.downloads!.store.playlists().first { $0.id == "pl-dw" }?.songIds == ["m-lullaby", "a-unknown", "m-ref1"])
    }

    // MARK: - Four setups

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func fourSetups(lidarr: Bool, aurralSetUp: Bool) async throws {
        let model = try await signedIn(aurralSetUp: aurralSetUp, lidarr: lidarr)
        if aurralSetUp { try await openPages(model, ["pl-dw"]) }
        await download(model, ["m-ref1"])
        let album = Album(id: "al-m-ref1", name: "A", artist: "Q", artistId: "ar-q", songCount: 2, duration: 200)
        await model.recordAlbumPage(album, songs: [Self.song("m-ref1"), Self.song("m-x")], into: model.downloads)
        await model.recordArtistPage(Artist(id: "ar-q", name: "Q", albumCount: 1), albums: [album], into: model.downloads)
        await model.recordPlaylistPage(Playlist(id: "pl-road", name: "Road trip", songCount: 2, duration: 200),
                                       songs: [Self.song("m-x"), Self.song("m-ref1")], kind: .playlist, into: model.downloads)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let catalog = await model.offlineCatalog
        #expect(catalog.albumPage(id: "al-m-ref1")?.total == 2, "albums (\(lidarr), \(aurralSetUp))")
        #expect(catalog.artistPage(id: "ar-q")?.albums.map(\.id) == ["al-m-ref1"], "artists")
        #expect(catalog.playlists(includingRecorded: true).map(\.id) == ["pl-road"], "playlists")
        #expect(await model.offlineFlows().map(\.id) == (aurralSetUp ? ["pl-dw"] : []), "flows only with Aurral")
    }
}

/// Round 28 O2 fix round 2: `D1Routing`, whose library-copy lookups (search and recording id) can be made to fail with
/// a server error (never a dropped connection, so nothing goes offline).
final class FailableD1Routing: HTTPTransport, @unchecked Sendable {
    let inner = D1Routing()
    private let failing = OSAllocatedUnfairLock(initialState: false)
    var failLookups: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isLookup = request.url?.path.hasSuffix("/rest/search3") == true
            || request.url?.query?.contains("mbz_recording_id") == true
        if isLookup, failLookups {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        return try await inner.send(request)
    }
}
