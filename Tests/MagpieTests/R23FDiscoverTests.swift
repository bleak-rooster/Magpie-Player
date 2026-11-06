import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

/// Round 23 R23F (owner, 2026-11-07): "I would like to see only my own [flows] but have a toggle to let me see all"
/// (D189, D190), and "an option to let me re-search Aurral playlist/flow songs that haven't downloaded or are stalled
/// … per playlist/flow" (D199, D200). Against the stub Aurral and a mock Navidrome, never the owner's.
@MainActor @Suite(.serialized) final class R23FDiscoverTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "R23FDiscoverTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "R23FDiscoverTests.\(UUID().uuidString)"
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

    /// Signed in to the small Navidrome and Aurral 2.13: the user's "Discover Weekly" (its four songs: two in, one
    /// that couldn't download, one never downloaded) and "Trending Mix", and Sam's "Late Night" ("sam - Late Night").
    private func signedIn(jobs: [StubAurral.Job]? = nil, setUp: (StubAurral) -> Void = { _ in }) async throws -> AppModel {
        nav.lists["pl-sam"] = ("sam - Late Night", ["a-old"])
        nav.install(on: transport.navidrome)
        aurral.useAurral213()
        aurral.addUser(id: 2, username: "sam", password: "sam-pw")
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly"), .init(id: "flow-tm", name: "Trending Mix"),
                         .init(id: "flow-sam", name: "Late Night", ownerUserId: 2)])
        aurral.setJobs(jobs ?? [
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", durationMs: 251_000),
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Words", status: "failed"),
            .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000, status: "saved"),
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Halo"),
            .init(flowId: "flow-sam", artistName: "Low", trackName: "Old", status: "failed"),
        ])
        setUp(aurral)
        let model = makeModel()
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                          password: StubAurral.defaultPassword)
        await model.refreshDiscover(force: true)
        return model
    }

    /// Where the phone and the car list playlists: Library › Playlists (All), Yours, and the car's Playlists.
    private func inPlaylists(_ model: AppModel) async throws -> Set<String> {
        let library = try await model.libraryPlaylists()
        let car = try await CarPlayLibraryAdapter(model: model).playlists()
        return Set(library.map(\.id)).union(car.map(\.id))
    }

    private func inDiscover(_ model: AppModel) async throws -> (phone: [String], car: [String]) {
        (try await model.discoverPlaylists().map(\.id), try await CarPlayLibraryAdapter(model: model).discoverPlaylists().map(\.id))
    }

    /// Aurral's writes to its data (its own login and logout aside).
    private var aurralWrites: [String] { aurral.asked.filter { $0.hasPrefix("POST") && !$0.hasPrefix("POST /api/auth/") } }

    // MARK: - D189: Discover shows your flows

    /// By default Discover (Home, Library › Discover and the car's) lists only the user's own flows and playlists;
    /// another user's is still Aurral's: out of Playlists, even with "Show Discover playlists in Playlists" on.
    @Test func onlyYourOwnFlowsByDefault() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(!model.showEveryonesFlows, "off by default")
        #expect(model.isDiscoverPlaylist(id: "pl-sam"), "still recognised as Aurral's (D184)")
        let discover = try await inDiscover(model)
        #expect(discover.phone.contains("pl-dw") && !discover.phone.contains("pl-sam"), "\(discover.phone)")
        #expect(discover.car == discover.phone)
        #expect(try await !inPlaylists(model).contains("pl-sam"))
        model.showDiscoverInPlaylists = true
        let playlists = try await inPlaylists(model)
        #expect(playlists.contains("pl-dw") && !playlists.contains("pl-sam"), "D188 shows only what Discover shows")
    }

    // MARK: - D190: Show everyone's flows

    /// On: other users' flows and playlists appear in Discover too, read-only (no Refresh, no Search again), never in
    /// Playlists either way; saved per account.
    @Test func showEveryonesFlowsSwitch() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.showEveryonesFlows = true
        let discover = try await inDiscover(model)
        #expect(discover.phone.contains("pl-dw") && discover.phone.contains("pl-sam"), "\(discover.phone)")
        #expect(discover.car == discover.phone)
        #expect(model.discoverFlow(playlistId: "pl-sam") == nil, "never Refresh someone else's flow")
        #expect(model.searchAgainFlow(playlistId: "pl-sam") == nil, "never Search again for someone else's")
        #expect(try await !inPlaylists(model).contains("pl-sam"))
        model.showDiscoverInPlaylists = true
        #expect(try await !inPlaylists(model).contains("pl-sam"), "never in Playlists, even with both switches on")
        let scope = try #require(model.navidromeScope)
        #expect(defaults.bool(forKey: AppModel.showEveryonesFlowsKeyPrefix + scope))
        #expect(EveryonesFlowsCopy.toggle == "Show everyone\u{2019}s flows and playlists")
        #expect(EveryonesFlowsCopy.footer == "Off: Discover shows only what you made. On: flows and playlists anyone on your server made appear too.")
    }

    /// A new flow of another user's is never started by itself (D186 only ever starts the user's own), switch on or off.
    @Test func othersFlowsNeverStartByThemselves() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.showEveryonesFlows = true
        var late = StubAurral.Flow(id: "flow-sam2", name: "Sam Manual", ownerUserId: 2)
        late.autoDownload = false
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly"), .init(id: "flow-tm", name: "Trending Mix"),
                         .init(id: "flow-sam", name: "Late Night", ownerUserId: 2), late])
        await model.refreshDiscover(force: true)
        await model.refreshDiscover(force: true)
        #expect(aurralWrites.isEmpty, "\(aurralWrites)")
    }

    /// Before Aurral answers (a relaunch, Aurral down) the ids saved for the account keep another user's playlist out
    /// of Discover (switch off) and out of Playlists.
    @Test func savedOthersKeptOutBeforeAurralAnswers() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.discover.forgetReads()
        aurral.setDown(true)
        await model.refreshDiscover(force: true)
        #expect(model.isDiscoverPlaylist(id: "pl-sam"))
        let phone = try await model.discoverPlaylists().map(\.id)
        #expect(phone.contains("pl-dw") && !phone.contains("pl-sam"), "\(phone)")
        #expect(try await !model.libraryPlaylists().contains { $0.id == "pl-sam" })
        model.showEveryonesFlows = true
        #expect(try await model.discoverPlaylists().contains { $0.id == "pl-sam" })
    }

    // MARK: - D199: Search again for missing songs

    /// Shown with the count of the flow's missing songs (failed or never downloaded); hidden when none is missing.
    @Test func offeredWithTheMissingCount() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.searchAgainFlow(playlistId: "pl-dw")?.id == "flow-dw")
        #expect(await model.missingSongs(playlistId: "pl-dw").map(\.trackName) == ["Words", "Unknown Song"])
        #expect(SearchAgainCopy.button(2) == "Search again for 2 missing songs")
        #expect(SearchAgainCopy.button(1) == "Search again for 1 missing song")
        #expect(SearchAgainCopy.confirmMessage == "Asks your server to look for these songs again.")
        #expect(await model.missingSongs(playlistId: "pl-empty").isEmpty, "Trending Mix: nothing missing, hidden")
        #expect(aurralWrites.isEmpty, "reading sends nothing")
    }

    /// After the owner confirms: each missing song sent once, one after another, through the allow-listed research
    /// route; "Looking again for 2 songs", then the jobs' outcome.
    @Test func searchesEachOnceAndReportsTheOutcome() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(try await model.searchAgain(playlistId: "pl-dw") == 2)
        #expect(aurralWrites == ["POST /api/playlists/shared-playlists/flow-dw/tracks/job-1/research",
                                 "POST /api/playlists/shared-playlists/flow-dw/tracks/job-2/research"], "\(aurralWrites)")
        #expect(model.searchAgainState(playlistId: "pl-dw") == .looking(2))
        #expect(SearchAgainCopy.text(.looking(2)) == "Looking again for 2 songs")
        await model.followSearchAgain(playlistId: "pl-dw")
        #expect(model.searchAgainState(playlistId: "pl-dw") == .looking(2), "still pending")
        aurral.setJobStatus("job-1", "done")
        aurral.setJobStatus("job-2", "failed")
        await model.followSearchAgain(playlistId: "pl-dw")
        let state = model.searchAgainState(playlistId: "pl-dw")
        #expect(state == .finished(SearchAgain.Outcome(found: 1, stillMissing: 1)))
        #expect(state.map(SearchAgainCopy.text) == "1 found, 1 still missing")
        #expect(aurralWrites.count == 2, "never sent again by itself")
    }

    /// D61's checks: nothing is sent while the flow's run is under way.
    @Test func notWhileARunIsUnderWay() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        aurral.setRunning("flow-dw", true)
        await #expect(throws: AurralError.runActive) { try await model.searchAgain(playlistId: "pl-dw") }
        #expect(aurralWrites.isEmpty)
    }

    /// D200: at most 25 songs per tap.
    @Test func atMostTwentyFivePerTap() async throws {
        let jobs = (0..<30).map { StubAurral.Job(flowId: "flow-dw", artistName: "Low", trackName: "Song \($0)", status: "failed") }
        let model = try await signedIn(jobs: jobs)
        defer { model.signOut() }
        #expect(try await model.searchAgain(playlistId: "pl-dw") == 25)
        #expect(aurralWrites.count == 25)
        #expect(Set(aurralWrites).count == 25, "each once")
    }

    /// Hidden without the capability (an older Aurral) and for another user's flow; a refusal (403: the account may
    /// not) is a quiet note on the page, nothing more sent.
    @Test func hiddenWithoutCapabilityAndQuietWhenRefused() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        aurral.setRole("user", for: StubAurral.defaultUsername)
        aurral.setPermissions(AurralPermissions(accessFlow: false, addArtist: true, addAlbum: true),
                              for: StubAurral.defaultUsername)
        _ = try? await model.searchAgain(playlistId: "pl-dw")
        #expect(model.searchAgainState(playlistId: "pl-dw") == .notAllowed)
        #expect(SearchAgainCopy.text(.notAllowed) == "Your account can\u{2019}t ask for songs again.")
        #expect(aurralWrites.isEmpty)
        await model.refreshAurralCapabilities(force: true)
        #expect(model.searchAgainFlow(playlistId: "pl-dw") == nil, "no permission: hidden")
    }

    @Test func hiddenOnAnOlderAurral() async throws {
        let model = try await signedIn { $0.setFeatures(nil) }
        defer { model.signOut() }
        await model.refreshAurralCapabilities(force: true)
        #expect(model.searchAgainFlow(playlistId: "pl-dw") == nil)
        #expect(await model.missingSongs(playlistId: "pl-dw").isEmpty)
    }
}
