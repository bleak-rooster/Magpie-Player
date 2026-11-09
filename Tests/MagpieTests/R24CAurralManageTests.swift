import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

/// The stub Aurral and the mock Navidrome (`AurralRouting`), with two faults a test can switch on: a delete Aurral
/// receives and runs whose answer is lost on the way back (fix round 1, I1), and an item's song list that can't be read
/// (M1). Never the owner's Aurral.
final class LossyAurralRouting: HTTPTransport, @unchecked Sendable {
    let inner = AurralRouting()
    private let lock = NSLock()
    private var losesDeleteAnswers = false
    private var deleteAnswer: Int?
    private var unreadable: Set<String> = []

    func loseDeleteAnswers(_ on: Bool) { lock.withLock { losesDeleteAnswers = on } }
    /// Follow-up m1: Aurral runs the delete, but what reaches Magpie is this status (a gateway's 504, say).
    func answerDeletes(with status: Int?) { lock.withLock { deleteAnswer = status } }
    func failJobsRead(for ids: Set<String>) { lock.withLock { unreadable = ids } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let (lose, fail, status) = lock.withLock { (losesDeleteAnswers, unreadable, deleteAnswer) }
        if fail.contains(where: { path == "/api/playlists/jobs/" + $0 }) { throw URLError(.timedOut) }
        let answer = try await inner.send(request)
        if lose, request.httpMethod == "DELETE" { throw URLError(.networkConnectionLost) }   // Aurral got it and ran it
        if let status, request.httpMethod == "DELETE", let url = request.url,
           let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) {
            return (Data("<html>Gateway Timeout</html>".utf8), http)
        }
        return answer
    }
}

/// Round 24 C (owner, 2026-11-08): "Delete Aurral playlists and flows" (item 5, D212) and "a page like the active Lidarr
/// downloads page, for Aurral: songs not yet downloaded, their state; search now, blocklist and re-search, approve a
/// download held for review" (item 6, D213, D214). Rulings Q4 (own items only, even for an Aurral admin) and Q5
/// (Approve, Try another source, Search now; no Cancel). Against the stub Aurral and a mock Navidrome, never the owner's.
@MainActor @Suite(.serialized) final class R24CAurralManageTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "R24CAurralManageTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "R24CAurralManageTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = LossyAurralRouting()
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()
    var aurral: StubAurral { transport.inner.aurral }

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

    private static let flows: [StubAurral.Flow] = [
        .init(id: "flow-dw", name: "Discover Weekly"), .init(id: "flow-tm", name: "Trending Mix"),
        .init(id: "flow-sam", name: "Late Night", ownerUserId: 2),
    ]

    /// Signed in (the stub's user is an Aurral admin) to the small Navidrome and Aurral 2.13: the user's flow "Discover
    /// Weekly" (job-0 in, job-1 held for review, job-2 not found) and "Trending Mix" (job-3 looking, job-4 downloading:
    /// its run is under way), the user's shared playlist "Road Songs" (job-7 in), and Sam's flow "Late Night" (job-5
    /// held, job-6 not found).
    private func signedIn(setUp: (StubAurral) -> Void = { _ in }) async throws -> AppModel {
        nav.lists["pl-sam"] = ("sam - Late Night", ["a-old"])
        nav.lists["pl-road-songs"] = ("Road Songs", ["a-words"])
        nav.install(on: transport.inner.navidrome)
        aurral.useAurral213()
        aurral.addUser(id: 2, username: "sam", password: "sam-pw")
        aurral.setFlows(Self.flows)
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

    /// Delete, as the confirmation does it: what was confirmed is what is sent.
    private func delete(_ model: AppModel, _ playlistId: String) async throws -> AurralRemovalState {
        let item = try #require(model.deletableAurralItem(playlistId: playlistId))
        return try await model.deleteAurralItem(playlistId: playlistId, confirmed: item)
    }

    /// The server's own refusal: the user is no longer allowed flows (Magpie's last read still says it is).
    private func refuseFlows() {
        aurral.setRole("user", for: StubAurral.defaultUsername)
        aurral.setPermissions(AurralPermissions(accessFlow: false, addArtist: true, addAlbum: true),
                              for: StubAurral.defaultUsername)
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
        await #expect(throws: AurralError.notPermitted) {
            _ = try await model.deleteAurralItem(playlistId: "pl-sam", confirmed: flow)
        }
        #expect(aurralWrites.isEmpty, "\(aurralWrites)")
    }

    /// The plan's words, exactly, and the fix round's.
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
        #expect(AurralDeleteCopy.unheard == "Magpie couldn\u{2019}t hear back from Aurral. It will check whether it\u{2019}s gone.")
        #expect(AurralDeleteCopy.alreadyGone == "It\u{2019}s no longer in Aurral.")
    }

    /// Sent once; "Aurral is removing it…" until the status no longer lists it; then Discover's saved ids for it are
    /// forgotten (Aurral removed its Navidrome copy too), so it leaves Discover and never shows up in Playlists.
    @Test func delete_forgetsSavedIds() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let scope = try #require(model.navidromeScope)
        #expect(defaults.stringArray(forKey: AppModel.discoverPlaylistsKey(scope))?.contains("pl-dw") == true)
        #expect(try await delete(model, "pl-dw") == .removing)
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
        #expect(try await delete(model, "pl-road-songs") == .removing)
        #expect(aurralWrites == ["DELETE /api/playlists/shared-playlists/shared-road"], "\(aurralWrites)")
        #expect(await untilGone(model, "pl-road-songs") == .deleted)
        #expect(model.isDiscoverPlaylist(id: "pl-road-songs"))
        #expect(model.discoverSyncedPlaylist(playlistId: "pl-road-songs") == nil)
        #expect(model.searchAgainFlow(playlistId: "pl-road-songs") == nil)
        #expect(model.deletableAurralItem(playlistId: "pl-road-songs") == nil)
        #expect(!(try await model.libraryPlaylists().contains { $0.id == "pl-road-songs" }))
    }

    /// B-L1: Aurral answered 404, which 2.13 gives alike for "gone" and "not yours": never "Deleted", only that it is no
    /// longer there. Nothing sent again.
    @Test func alreadyGoneIsNotClaimedAsDeleted() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let item = try #require(model.deletableAurralItem(playlistId: "pl-dw"))
        aurral.setFlows(Array(Self.flows.dropFirst()))
        #expect(try await model.deleteAurralItem(playlistId: "pl-dw", confirmed: item) == .alreadyGone)
        #expect(aurralWrites == ["DELETE /api/playlists/flows/flow-dw"])
        #expect(model.aurralRemoval(playlistId: "pl-dw") == nil)
    }

    /// A delete Aurral queued but hasn't run after `aurralRemovalLimit`: "Aurral is still removing it.", the record
    /// goes and Delete is offered again; nothing is sent again by itself.
    @Test func aQueuedDeleteThatNeverRunsSaysSo() async throws {
        let model = try await signedIn { $0.setDeleteDelay(reads: 1000) }
        defer { model.signOut() }
        var now = Date()
        model.discover.now = { now }
        #expect(try await delete(model, "pl-dw") == .removing)
        #expect(await model.checkAurralRemoval(playlistId: "pl-dw") == .removing)
        now = now.addingTimeInterval(AppModel.aurralRemovalLimit + 1)
        #expect(await model.checkAurralRemoval(playlistId: "pl-dw") == .stillRemoving)
        #expect(model.aurralRemoval(playlistId: "pl-dw") == nil, "the record goes")
        #expect(model.deletableAurralItem(playlistId: "pl-dw") != nil, "Delete is offered again")
        #expect(aurralWrites.count == 1)
    }

    /// I1: the answer is lost (Aurral got the delete and runs it): the record stays, "Magpie couldn't hear back", the
    /// page checks as for a queued delete, the item goes once Aurral has run it, and nothing is ever sent again.
    @Test func aLostAnswerKeepsCheckingAndNeverResends() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        transport.loseDeleteAnswers(true)
        #expect(try await delete(model, "pl-dw") == .unheard)
        #expect(model.aurralRemoval(playlistId: "pl-dw") != nil, "kept: it may have gone through")
        #expect(model.deletableAurralItem(playlistId: "pl-dw") == nil, "not offered again while checking")
        nav.lists["pl-dw"] = nil
        #expect(await untilGone(model, "pl-dw") == .deleted)
        #expect(!model.discover.playlists.contains { $0.playlist.id == "pl-dw" })
        #expect(aurralWrites == ["DELETE /api/playlists/flows/flow-dw"], "never sent again")
    }

    /// Follow-up m1: a 504 (a gateway gave up while Aurral queued the delete) isn't a refusal: the record stays, Magpie
    /// says it couldn't hear back and checks; the item goes once Aurral has run it; nothing is sent again.
    @Test func aGatewayTimeoutIsUnheard() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        transport.answerDeletes(with: 504)
        #expect(try await delete(model, "pl-dw") == .unheard)
        #expect(model.aurralRemoval(playlistId: "pl-dw") != nil)
        nav.lists["pl-dw"] = nil
        #expect(await untilGone(model, "pl-dw") == .deleted)
        #expect(aurralWrites == ["DELETE /api/playlists/flows/flow-dw"], "never sent again")
        #expect(AppModel.isDefiniteRefusal(AurralError.http(status: 409)))
        #expect(!AppModel.isDefiniteRefusal(AurralError.http(status: 500)))
        #expect(!AppModel.isDefiniteRefusal(AurralError.decoding))
        #expect(!AppModel.isDefiniteRefusal(URLError(.timedOut)))
    }

    /// I1: a definite refusal (Aurral answered 403): the mark goes, "Aurral couldn't delete it. Nothing was changed.",
    /// and Delete may be asked for again.
    @Test func aRefusedDeleteChangesNothing() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        refuseFlows()
        await #expect(throws: AurralError.notPermitted) { _ = try await self.delete(model, "pl-dw") }
        #expect(model.aurralRemoval(playlistId: "pl-dw") == nil)
        #expect(model.isDiscoverPlaylist(id: "pl-dw"))
        #expect(aurralWrites == ["DELETE /api/playlists/flows/flow-dw"])
        #expect(AurralDeleteCopy.message(for: AurralError.notPermitted) == AurralDeleteCopy.failed)
        #expect(AurralDeleteCopy.message(for: URLError(.timedOut)) == AurralDeleteCopy.failed, "not sent at all")
    }

    /// I6: what is sent is what was confirmed: the page's link changed between the confirmation and the send (now
    /// another flow's playlist): nothing is sent.
    @Test func aChangedLinkSendsNothing() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let confirmed = try #require(model.deletableAurralItem(playlistId: "pl-dw"))
        let trending = try #require(model.discover.status?.flows.first { $0.id == "flow-tm" })
        model.discover.playlists = model.discover.playlists.map {
            $0.playlist.id == "pl-dw" ? DiscoverPlaylist(flow: trending, playlist: $0.playlist) : $0
        }
        await #expect(throws: AurralDeleteRefusal.changed) {
            _ = try await model.deleteAurralItem(playlistId: "pl-dw", confirmed: confirmed)
        }
        #expect(aurralWrites.isEmpty, "\(aurralWrites)")
        #expect(model.aurralRemoval(playlistId: "pl-dw") == nil)
    }

    @Test func delete_hiddenOffline() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let item = try #require(model.deletableAurralItem(playlistId: "pl-dw"))
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.deletableAurralItem(playlistId: "pl-dw") == nil)
        await #expect(throws: (any Error).self) { _ = try await model.deleteAurralItem(playlistId: "pl-dw", confirmed: item) }
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(aurralWrites.isEmpty)
    }

    /// Without accessFlow (or on an Aurral without the routes) neither Delete nor the page's actions show.
    @Test func delete_hiddenWithoutAccessFlow() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        refuseFlows()
        await model.refreshAurralCapabilities(force: true)
        #expect(model.deletableAurralItem(playlistId: "pl-dw") == nil)
        #expect(!model.songsStillComingAvailable)
        #expect(model.heldSongsWaiting == 0, "no Home banner")
    }

    /// M8 (ruling): an item with no owner (from before Aurral had users; an admin's by D72(5)) is never offered Delete,
    /// even to an admin; its held and missing songs follow D72(5) unchanged (the admin's to decide).
    @Test func ownerlessItems() async throws {
        nav.lists["pl-old"] = ("Old Mix", ["a-words"])
        let model = try await signedIn { stub in
            stub.setFlows(Self.flows + [.init(id: "flow-old", name: "Old Mix", ownerUserId: nil)])
            stub.setJobs([.init(flowId: "flow-old", artistName: "Low", trackName: "Ancient", status: "blocked"),
                          .init(flowId: "flow-old", artistName: "Low", trackName: "Lost", status: "failed")])
        }
        defer { model.signOut() }
        #expect(model.isDiscoverPlaylist(id: "pl-old"), "precondition: Aurral's")
        #expect(model.deletableAurralItem(playlistId: "pl-old") == nil, "never Delete on an ownerless item")
        let board = try await model.readSongsStillComing()
        #expect(model.actions(for: try #require(board.held.first)) == [.approve, .tryAnotherSource])
        #expect(model.actions(for: try #require(board.notFound.first)) == [.searchNow])
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
        #expect(board.unread.isEmpty)
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
        #expect(SongsStillComingCopy.heldNote == "Aurral held this copy back for you to decide.")
        #expect(SongsStillComingCopy.heading(.notFound) == "Not found")
        #expect(SongsStillComingCopy.symbol(.notFound) == "magnifyingglass")
        #expect(SongsStillComingCopy.heading(.looking) == "Looking")
        #expect(SongsStillComingCopy.heading(.downloading) == "Downloading")
        #expect(SongsStillComingCopy.heading(.doneRecently) == "Done recently")
        #expect(SongsStillComingCopy.unreachable == "Couldn\u{2019}t check on your songs. Trying again\u{2026}")
    }

    /// I4: a song's progress and Aurral's words about it show when Aurral gives them, and nothing when it doesn't.
    @Test func progressAndMessageWhenPresent() async throws {
        let model = try await signedIn { stub in
            stub.setJobDetail("job-4", progress: 0.4, message: "Downloading from a peer")
            stub.setJobDetail("job-3", progress: nil, message: "  Waiting for a slot  ")
        }
        defer { model.signOut() }
        let board = try await model.readSongsStillComing()
        let downloading = try #require(board.downloading.first)
        #expect(downloading.job.progress == 40 && downloading.job.message == "Downloading from a peer")
        let looking = try #require(board.looking.first)
        #expect(looking.job.progress == nil && looking.job.message == "Waiting for a slot")
        #expect(board.held.first?.job.progress == nil && board.held.first?.job.message == nil, "absent: nothing")
        #expect(SongsStillComingCopy.progress(40) == "40%")
    }

    /// M1: an item whose songs couldn't be read keeps its previous rows (and says so), never "nothing there".
    @Test func anUnreadableItemKeepsItsRows() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let first = try await model.readSongsStillComing()
        transport.failJobsRead(for: ["flow-dw"])
        let kept = try await model.readSongsStillComing(previous: first)
        #expect(kept.held.map(\.job.id) == ["job-1"], "the previous rows")
        #expect(kept.notFound.map(\.job.id) == ["job-2"])
        #expect(kept.unread == ["flow-dw"])
        let fresh = try await model.readSongsStillComing()
        #expect(fresh.unread == ["flow-dw"] && fresh.held.isEmpty, "with nothing before, marked unread, not empty")
    }

    /// A held song of the user's own: Approve and Try another source; a song not found: Search now; looking and
    /// downloading: nothing. No Cancel anywhere (Q5). A song being asked about offers nothing (I5).
    @Test func downloads_heldShowsApproveAndAnother() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let board = try await model.readSongsStillComing()
        let held = try #require(board.held.first)
        #expect(model.actions(for: held) == [.approve, .tryAnotherSource])
        #expect(model.actions(for: try #require(board.notFound.first)) == [.searchNow])
        #expect(model.actions(for: try #require(board.looking.first)).isEmpty)
        #expect(model.actions(for: try #require(board.downloading.first)).isEmpty)
        #expect(SongsStillComingCopy.approve == "Approve")
        #expect(SongsStillComingCopy.tryAnotherSource == "Try another source")
        #expect(SongsStillComingCopy.searchNow == "Search now")
        model.discover.songsAsking.insert(held.job.id)
        #expect(model.actions(for: held).isEmpty, "in flight")
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
        var forged = sams
        forged.own = true
        await #expect(throws: AurralError.notPermitted) { try await model.approve(forged) }
        #expect(try await model.searchNowAll(board) == SearchNowOutcome(sent: 1, refused: false), "only the user's own")
        #expect(aurralWrites == ["POST /api/playlists/shared-playlists/flow-dw/tracks/job-2/research"], "\(aurralWrites)")
        #expect(aurral.jobStatus("job-5") == "blocked", "Sam's held song untouched")
    }

    /// B-M1: ownership and the hold are read fresh right before Approve: an item no longer the user's, or a song no
    /// longer held, is never sent.
    @Test func approveChecksOwnershipAndHoldFresh() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let held = try #require(try await model.readSongsStillComing().held.first)
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly", ownerUserId: 2)] + Self.flows.dropFirst())
        await #expect(throws: AurralError.notPermitted) { try await model.approve(held) }
        aurral.setFlows(Self.flows)
        await model.refreshDiscoverStatus()   // the user's own again, as last read
        aurral.setJobStatus("job-1", "done")
        await #expect(throws: AurralError.notHeldAnyMore) { try await model.tryAnotherSource(held) }
        #expect(aurralWrites.isEmpty, "\(aurralWrites)")
    }

    /// Approve: sent once; the page then reads again and the song is in.
    @Test func approve_sendsOnce_thenRefreshes() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let held = try #require(try await model.readSongsStillComing().held.first)
        try await model.approve(held)
        #expect(aurralWrites == ["POST /api/playlists/jobs/job-1/approve"], "\(aurralWrites)")
        let board = try await model.readSongsStillComing()
        #expect(board.held.isEmpty)
        #expect(board.doneRecently.contains { $0.job.id == "job-1" })
        #expect(SongsStillComingCopy.approveTitle == "Add this copy to your library?")
        // Asked again from a stale row: the fresh read shows it isn't held; said plainly, never sent again.
        await #expect(throws: AurralError.notHeldAnyMore) { try await model.approve(held) }
        #expect(aurralWrites.count == 1)
        #expect(SongsStillComingCopy.message(for: AurralError.notHeldAnyMore) == "That song isn\u{2019}t waiting for you any more.")
    }

    /// I5: two Approves at once on one song: exactly one is sent.
    @Test func twoApprovesAtOnceSendOne() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let held = try #require(try await model.readSongsStillComing().held.first)
        async let first: Void = model.approve(held)
        async let second: Void = model.approve(held)
        var sent = 0
        do { try await first; sent += 1 } catch {}
        do { try await second; sent += 1 } catch {}
        #expect(sent == 1)
        #expect(aurralWrites == ["POST /api/playlists/jobs/job-1/approve"], "\(aurralWrites)")
        #expect(model.discover.songsAsking.isEmpty, "cleared after")
    }

    /// Try another source: after its confirmation, Aurral's deny, sent once; the song is looked for again.
    @Test func deny_confirmationThenSends() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(SongsStillComingCopy.tryAnotherSourceMessage == "Aurral won\u{2019}t use that copy again and looks for another.")
        let held = try #require(try await model.readSongsStillComing().held.first)
        try await model.tryAnotherSource(held)
        #expect(aurralWrites == ["POST /api/playlists/jobs/job-1/deny"], "\(aurralWrites)")
        #expect(aurral.deniedJobs == ["job-1"])
        #expect(try await model.readSongsStillComing().looking.contains { $0.job.id == "job-1" })
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
        nav.install(on: transport.inner.navidrome)
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
        try await model.searchNow(missing)
        #expect(aurralWrites == ["POST /api/playlists/shared-playlists/flow-dw/tracks/job-2/research"], "\(aurralWrites)")
        #expect(SongsStillComingCopy.searchNowAll(3) == "Search now for 3")
        aurral.setRunning("flow-dw", true)
        await #expect(throws: AurralError.runActive) { try await model.searchNow(missing) }
        #expect(try await model.searchNowAll(board).sent == 0, "a run under way: nothing sent")
        #expect(aurralWrites.count == 1)
    }

    /// M3: "Search now for N" reads the songs fresh (one found meanwhile isn't sent), and a refusal says D199's words.
    @Test func searchNowAllReadsFreshAndSaysWhenRefused() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let board = try await model.readSongsStillComing()
        aurral.setJobStatus("job-2", "done")
        #expect(try await model.searchNowAll(board) == SearchNowOutcome(sent: 0, refused: false))
        #expect(aurralWrites.isEmpty)
        aurral.setJobStatus("job-2", "failed")
        refuseFlows()
        await #expect(throws: AurralError.notPermitted) { _ = try await model.searchNowAll(board) }
        #expect(aurralWrites.isEmpty)
        #expect(SongsStillComingCopy.searchNowAllMessage(for: AurralError.notPermitted) == "Your account can\u{2019}t ask for songs again.")
        #expect(SongsStillComingCopy.searchNowAllRefused == "Your account can\u{2019}t ask for songs again.")
    }

    /// Offline nothing is offered or sent.
    @Test func actionsHiddenOffline() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let board = try await model.readSongsStillComing()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let held = try #require(board.held.first)
        #expect(model.actions(for: held).isEmpty)
        #expect(model.actions(for: try #require(board.notFound.first)).isEmpty)
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
