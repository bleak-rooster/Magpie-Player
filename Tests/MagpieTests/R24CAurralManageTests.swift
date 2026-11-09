import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

/// Round 24 C (owner, 2026-11-08): "Delete Aurral playlists and flows" (item 5, D212) and "a page like the active Lidarr
/// downloads page, for Aurral: songs not yet downloaded, their state; search now, blocklist and re-search, approve a
/// download held for review" (item 6, D213, D214). Rulings Q4 (own items only, even for an Aurral admin) and Q5
/// (Approve, Try another source, Search now; no Cancel). Against the stub Aurral and a mock Navidrome, never the owner's.
@MainActor @Suite(.serialized) final class R24CAurralManageTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "R24CAurralManageTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "R24CAurralManageTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = AurralRouting()
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()
    var aurral: StubAurral { transport.aurral }

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), aurralStore: aurralStore,
                 matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                 network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
    }

    /// Signed in (the stub's user is an Aurral admin) to the small Navidrome and Aurral 2.13: the user's flow "Discover
    /// Weekly" (job-0 in, job-1 held for review, job-2 not found) and "Trending Mix" (job-3 looking, job-4 downloading:
    /// its run is under way), the user's shared playlist "Road Songs" (job-7 in), and Sam's flow "Late Night" (job-5
    /// held, job-6 not found).
    private func signedIn(setUp: (StubAurral) -> Void = { _ in }) async throws -> AppModel {
        nav.lists["pl-sam"] = ("sam - Late Night", ["a-old"])
        nav.lists["pl-road-songs"] = ("Road Songs", ["a-words"])
        nav.install(on: transport.navidrome)
        aurral.useAurral213()
        aurral.addUser(id: 2, username: "sam", password: "sam-pw")
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly"), .init(id: "flow-tm", name: "Trending Mix"),
                         .init(id: "flow-sam", name: "Late Night", ownerUserId: 2)])
        aurral.setJobs([
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", durationMs: 251_000),
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Words", status: "blocked"),
            .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000, status: "failed"),
            .init(flowId: "flow-tm", artistName: "Low", trackName: "Halo", status: "pending"),
            .init(flowId: "flow-tm", artistName: "Low", trackName: "Sunflower", status: "downloading"),
            .init(flowId: "flow-sam", artistName: "Low", trackName: "Old", status: "blocked"),
            .init(flowId: "flow-sam", artistName: "Low", trackName: "Older", status: "failed"),
        ])
        aurral.addSharedPlaylist(id: "shared-road", name: "Road Songs", provider: nil,
                                 songs: [(title: "Words", artist: "Low", durationMs: 200_000)])
        setUp(aurral)
        let model = makeModel()
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                          password: StubAurral.defaultPassword)
        await model.refreshDiscover(force: true)
        return model
    }

    /// Aurral's writes (its own login and logout aside).
    private var aurralWrites: [String] {
        aurral.asked.filter { ($0.hasPrefix("POST") || $0.hasPrefix("DELETE") || $0.hasPrefix("PUT"))
            && !$0.hasPrefix("POST /api/auth/") }
    }

    /// Reads Aurral's status until the item's queued delete has run (the stub keeps it one more read).
    private func untilGone(_ model: AppModel, _ playlistId: String) async -> AurralRemovalState? {
        var state = await model.checkAurralRemoval(playlistId: playlistId)
        for _ in 0..<5 where state == .removing { state = await model.checkAurralRemoval(playlistId: playlistId) }
        return state
    }

    // MARK: - D212: Delete flow / Delete playlist

    /// Offered on the user's own flow ("Delete flow") and own Aurral playlist ("Delete playlist"); never on another
    /// user's, even though this user is an Aurral admin who could (Q4), and never on a playlist kept without a flow.
    @Test func delete_offeredOnlyOnOwn() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.showEveryonesFlows = true
        #expect(model.discover.bootstrap?.user?.isAdmin == true, "precondition: an Aurral admin")
        let flow = try #require(model.deletableAurralItem(playlistId: "pl-dw"))
        #expect(flow.kind == .flow && flow.id == "flow-dw" && flow.name == "Discover Weekly")
        let playlist = try #require(model.deletableAurralItem(playlistId: "pl-road-songs"))
        #expect(playlist.kind == .playlist && playlist.id == "shared-road")
        #expect(model.isDiscoverPlaylist(id: "pl-sam"), "precondition: Sam's is Aurral's")
        #expect(model.deletableAurralItem(playlistId: "pl-sam") == nil, "never another user's")
        #expect(model.deletableAurralItem(playlistId: "pl-mine") == nil, "never the owner's own playlist")
        #expect(AurralDeleteCopy.menuItem(.flow) == "Delete flow")
        #expect(AurralDeleteCopy.menuItem(.playlist) == "Delete playlist")
        await #expect(throws: AurralError.notPermitted) { _ = try await model.deleteAurralItem(playlistId: "pl-sam") }
        #expect(aurralWrites.isEmpty, "\(aurralWrites)")
    }

    /// The plan's words, exactly.
    @Test func delete_confirmationCopyExact() {
        #expect(AurralDeleteCopy.title("Discover Weekly") == "Delete \u{201C}Discover Weekly\u{201D}?")
        #expect(AurralDeleteCopy.message(.flow) == "Aurral stops making it and removes its songs from your Aurral library unless another playlist uses them. This can\u{2019}t be undone.")
        #expect(AurralDeleteCopy.message(.playlist) == "Aurral removes this playlist and the songs only it was keeping. This can\u{2019}t be undone.")
        #expect(AurralDeleteCopy.confirm == "Delete")
        #expect(AurralDeleteCopy.keep == "Keep it")
        #expect(AurralDeleteCopy.deleted("Discover Weekly") == "Deleted \u{201C}Discover Weekly\u{201D}.")
        #expect(AurralDeleteCopy.failed == "Aurral couldn\u{2019}t delete it. Nothing was changed.")
        #expect(AurralDeleteCopy.removing == "Aurral is removing it\u{2026}")
        #expect(AurralDeleteCopy.stillRemoving == "Aurral is still removing it.")
    }

    /// Sent once; "Aurral is removing it…" until the status no longer lists it; then Discover's saved ids for it are
    /// forgotten (Aurral removed its Navidrome copy too), so it leaves Discover and never shows up in Playlists.
    @Test func delete_forgetsSavedIds() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let scope = try #require(model.navidromeScope)
        #expect(defaults.stringArray(forKey: AppModel.discoverPlaylistsKey(scope))?.contains("pl-dw") == true)
        #expect(try await model.deleteAurralItem(playlistId: "pl-dw") == .removing)
        #expect(aurralWrites == ["DELETE /api/playlists/flows/flow-dw"], "\(aurralWrites)")
        #expect(model.aurralRemoval(playlistId: "pl-dw") != nil, "in flight")
        #expect(model.deletableAurralItem(playlistId: "pl-dw") == nil, "never offered twice")
        #expect(model.isDiscoverPlaylist(id: "pl-dw"), "stays until Aurral has run it")
        nav.lists["pl-dw"] = nil   // Aurral's delete removes its own Navidrome playlist
        #expect(await untilGone(model, "pl-dw") == .deleted)
        #expect(!model.discover.playlists.contains { $0.playlist.id == "pl-dw" })
        #expect(defaults.stringArray(forKey: AppModel.discoverPlaylistsKey(scope))?.contains("pl-dw") == false)
        #expect(model.aurralRemoval(playlistId: "pl-dw") == nil)
        #expect(!(try await model.libraryPlaylists().contains { $0.id == "pl-dw" }))
        #expect(aurralWrites == ["DELETE /api/playlists/flows/flow-dw"], "never sent again")
        #expect(nav.updates.isEmpty, "Magpie never changes or deletes the Navidrome playlist itself")
    }

    /// Aurral has run the delete but its Navidrome copy is still listed: when in doubt, leave out. It stays out of
    /// Playlists, and without its flow (no Refresh Flow, no Search again, no Delete) until a read shows it gone.
    @Test func deletedButNavidromeCopyLingers() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(try await model.deleteAurralItem(playlistId: "pl-road-songs") == .removing)
        #expect(aurralWrites == ["DELETE /api/playlists/shared-playlists/shared-road"], "\(aurralWrites)")
        #expect(await untilGone(model, "pl-road-songs") == .deleted)
        #expect(model.isDiscoverPlaylist(id: "pl-road-songs"))
        #expect(model.discoverSyncedPlaylist(playlistId: "pl-road-songs") == nil)
        #expect(model.searchAgainFlow(playlistId: "pl-road-songs") == nil)
        #expect(model.deletableAurralItem(playlistId: "pl-road-songs") == nil)
        #expect(!(try await model.libraryPlaylists().contains { $0.id == "pl-road-songs" }))
    }

    /// Aurral answered 404 (already gone): deleted at once, nothing sent again.
    @Test func alreadyGoneIsDeleted() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        aurral.setFlows([.init(id: "flow-tm", name: "Trending Mix"), .init(id: "flow-sam", name: "Late Night", ownerUserId: 2)])
        #expect(try await model.deleteAurralItem(playlistId: "pl-dw") == .deleted)
        #expect(aurralWrites == ["DELETE /api/playlists/flows/flow-dw"])
        #expect(model.aurralRemoval(playlistId: "pl-dw") == nil)
    }

    /// A delete Aurral queued but hasn't run after `aurralRemovalLimit`: "Aurral is still removing it." The page stops
    /// asking; nothing is sent again.
    @Test func aQueuedDeleteThatNeverRunsSaysSo() async throws {
        let model = try await signedIn { $0.setDeleteDelay(reads: 1000) }
        defer { model.signOut() }
        var now = Date()
        model.discover.now = { now }
        #expect(try await model.deleteAurralItem(playlistId: "pl-dw") == .removing)
        #expect(await model.checkAurralRemoval(playlistId: "pl-dw") == .removing)
        now = now.addingTimeInterval(AppModel.aurralRemovalLimit + 1)
        #expect(await model.checkAurralRemoval(playlistId: "pl-dw") == .stillRemoving)
        #expect(aurralWrites.count == 1)
    }

    /// A refusal: "Aurral couldn't delete it. Nothing was changed."; nothing marked as removing.
    @Test func aFailedDeleteChangesNothing() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        aurral.setDown(true)
        await #expect(throws: (any Error).self) { _ = try await model.deleteAurralItem(playlistId: "pl-dw") }
        #expect(model.aurralRemoval(playlistId: "pl-dw") == nil)
        #expect(model.isDiscoverPlaylist(id: "pl-dw"))
    }

    @Test func delete_hiddenOffline() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.deletableAurralItem(playlistId: "pl-dw") != nil)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.deletableAurralItem(playlistId: "pl-dw") == nil)
        await #expect(throws: (any Error).self) { _ = try await model.deleteAurralItem(playlistId: "pl-dw") }
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(aurralWrites.isEmpty)
    }

    /// Without accessFlow (or on an Aurral without the routes) neither Delete nor the page's actions show.
    @Test func delete_hiddenWithoutAccessFlow() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        aurral.setRole("user", for: StubAurral.defaultUsername)
        aurral.setPermissions(AurralPermissions(accessFlow: false, addArtist: true, addAlbum: true),
                              for: StubAurral.defaultUsername)
        await model.refreshAurralCapabilities(force: true)
        #expect(model.deletableAurralItem(playlistId: "pl-dw") == nil)
        #expect(!model.songsStillComingAvailable)
        #expect(model.heldSongsWaiting == 0, "no Home banner")
    }

    // MARK: - D213: Songs still coming

    /// Every song of the user's own flows and playlists in its section (another user's only with "Show everyone's
    /// flows" on), read through the status and each item's jobs only.
    @Test func downloads_groupsByState() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.songsStillComingAvailable)
        let board = try await model.readSongsStillComing()
        #expect(board.held.map(\.job.trackName) == ["Words"])
        #expect(board.notFound.map(\.job.trackName) == ["Unknown Song"])
        #expect(board.looking.map(\.job.trackName) == ["Halo"])
        #expect(board.downloading.map(\.job.trackName) == ["Sunflower"])
        #expect(board.doneRecently.map(\.job.trackName).contains("Lullaby"))
        #expect(board.held.map(\.own) == [true])
        model.showEveryonesFlows = true
        let everyone = try await model.readSongsStillComing()
        #expect(everyone.held.map(\.job.trackName) == ["Words", "Old"])
        #expect(everyone.held.last?.own == false && everyone.held.last?.item.ownerUsername == "sam")
        let reads = Set(aurral.asked.filter { $0.hasPrefix("GET /api/playlists") })
        #expect(reads.isSubset(of: ["GET /api/playlists/status", "GET /api/playlists/jobs", "GET /api/playlists/jobs/flow-dw",
                                    "GET /api/playlists/jobs/flow-tm", "GET /api/playlists/jobs/shared-road",
                                    "GET /api/playlists/jobs/flow-sam"]), "\(reads)")
        #expect(aurralWrites.isEmpty, "reading sends nothing")
        #expect(SongsStillComingCopy.title == "Songs still coming")
        #expect(SongsStillComingCopy.heading(.held) == "Held for review")
        #expect(SongsStillComingCopy.symbol(.held) == "hand.raised")
        #expect(SongsStillComingCopy.heldNote == "Aurral held this copy back. Listen to decide.")
        #expect(SongsStillComingCopy.heading(.notFound) == "Not found")
        #expect(SongsStillComingCopy.symbol(.notFound) == "magnifyingglass")
        #expect(SongsStillComingCopy.heading(.looking) == "Looking")
        #expect(SongsStillComingCopy.heading(.downloading) == "Downloading")
        #expect(SongsStillComingCopy.heading(.doneRecently) == "Done recently")
    }

    /// A held song of the user's own: Approve and Try another source; a song not found: Search now; looking and
    /// downloading: nothing. No Cancel anywhere (Q5).
    @Test func downloads_heldShowsApproveAndAnother() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let board = try await model.readSongsStillComing()
        #expect(model.actions(for: try #require(board.held.first)) == [.approve, .tryAnotherSource])
        #expect(model.actions(for: try #require(board.notFound.first)) == [.searchNow])
        #expect(model.actions(for: try #require(board.looking.first)).isEmpty)
        #expect(model.actions(for: try #require(board.downloading.first)).isEmpty)
        #expect(SongsStillComingCopy.approve == "Approve")
        #expect(SongsStillComingCopy.tryAnotherSource == "Try another source")
        #expect(SongsStillComingCopy.searchNow == "Search now")
    }

    /// Another user's songs are read only, even for an Aurral admin (Aurral 2.13 doesn't check whose song it is): no
    /// action shown, and none sent if asked.
    @Test func downloads_actionsOnlyOnOwn() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.showEveryonesFlows = true
        let board = try await model.readSongsStillComing()
        let sams = try #require(board.held.first { !$0.own })
        let samsMissing = try #require(board.notFound.first { !$0.own })
        #expect(model.actions(for: sams).isEmpty)
        #expect(model.actions(for: samsMissing).isEmpty)
        await #expect(throws: AurralError.notPermitted) { try await model.approve(sams) }
        await #expect(throws: AurralError.notPermitted) { try await model.tryAnotherSource(sams) }
        await #expect(throws: AurralError.notPermitted) { try await model.searchNow(samsMissing) }
        #expect(try await model.searchNowAll(board) == 1, "only the user's own")
        #expect(aurralWrites == ["POST /api/playlists/shared-playlists/flow-dw/tracks/job-2/research"], "\(aurralWrites)")
        #expect(aurral.jobStatus("job-5") == "blocked", "Sam's held song untouched")
    }

    /// Approve: sent once, then the page reads again and the song is in.
    @Test func approve_sendsOnce_thenRefreshes() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let held = try #require(try await model.readSongsStillComing().held.first)
        let board = try await model.approve(held)
        #expect(aurralWrites == ["POST /api/playlists/jobs/job-1/approve"], "\(aurralWrites)")
        #expect(board.held.isEmpty)
        #expect(board.doneRecently.contains { $0.job.id == "job-1" })
        #expect(SongsStillComingCopy.approveTitle == "Add this copy to your library?")
        // Approved meanwhile (another phone): Aurral answers 404; said plainly, not sent again.
        await #expect(throws: AurralError.notHeldAnyMore) { try await model.approve(held) }
        #expect(aurralWrites.count == 2)
        #expect(SongsStillComingCopy.message(for: AurralError.notHeldAnyMore) == "That song isn\u{2019}t waiting for you any more.")
    }

    /// Try another source: after its confirmation, Aurral's deny, sent once; the song is looked for again.
    @Test func deny_confirmationThenSends() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(SongsStillComingCopy.tryAnotherSourceMessage == "Aurral won\u{2019}t use that copy again and looks for another.")
        let held = try #require(try await model.readSongsStillComing().held.first)
        let board = try await model.tryAnotherSource(held)
        #expect(aurralWrites == ["POST /api/playlists/jobs/job-1/deny"], "\(aurralWrites)")
        #expect(aurral.deniedJobs == ["job-1"])
        #expect(board.looking.contains { $0.job.id == "job-1" })
    }

    @Test func downloads_emptyState() async throws {
        let model = try await signedIn { $0.setJobs([.init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby")]) }
        defer { model.signOut() }
        let board = try await model.readSongsStillComing()
        #expect(board.isEmpty)
        #expect(SongsStillComingCopy.empty == "Nothing is waiting on Aurral.")
        #expect(model.heldSongsWaiting == 0)
    }

    /// Without Aurral the page's entry and the Home banner are absent.
    @Test func downloads_hiddenWithoutAurral() async throws {
        nav.install(on: transport.navidrome)
        let model = makeModel()
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        defer { model.signOut() }
        #expect(!model.songsStillComingAvailable)
        #expect(model.heldSongsWaiting == 0)
        await #expect(throws: (any Error).self) { _ = try await model.readSongsStillComing() }
    }

    /// Search now is D199's Retry route, and only it: one song at once; "Search now for N" each own missing song once,
    /// not while its flow's run is under way.
    @Test func searchNow_usesRetryRouteOnly() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let board = try await model.readSongsStillComing()
        let missing = try #require(board.notFound.first)
        _ = try await model.searchNow(missing)
        #expect(aurralWrites == ["POST /api/playlists/shared-playlists/flow-dw/tracks/job-2/research"], "\(aurralWrites)")
        #expect(SongsStillComingCopy.searchNowAll(3) == "Search now for 3")
        aurral.setRunning("flow-dw", true)
        await #expect(throws: AurralError.runActive) { try await model.searchNow(missing) }
        #expect(try await model.searchNowAll(board) == 0, "a run under way: nothing sent")
        #expect(aurralWrites.count == 1)
    }

    /// Offline nothing is offered or sent.
    @Test func actionsHiddenOffline() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let board = try await model.readSongsStillComing()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.actions(for: try #require(board.held.first)).isEmpty)
        #expect(model.actions(for: try #require(board.notFound.first)).isEmpty)
        let held = try #require(board.held.first)
        await #expect(throws: (any Error).self) { try await model.approve(held) }
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(aurralWrites.isEmpty)
    }

    /// Home's banner: how many of the user's own songs Aurral holds for review (from the jobs Discover already reads).
    @Test func homeBannerCountsOwnHeldSongs() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.heldSongsWaiting == 1, "Sam's held song never counts")
        #expect(SongsStillComingCopy.banner(1) == "1 song is waiting for you to decide")
        #expect(SongsStillComingCopy.banner(2) == "2 songs are waiting for you to decide")
    }
}
