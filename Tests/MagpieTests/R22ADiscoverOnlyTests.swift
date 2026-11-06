import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Testing
@testable import Magpie

/// Round 22 R22A (owner, 2026-11-06): "when I have aurral connected, all of the playlists (flows) that are within
/// Aurral are kept separate from Magpie Playlists and rather exist in Discover only" (D181–D185). Against the stub
/// Aurral and a mock Navidrome (`DiscoverAppTests`' small server), never the owner's.
@MainActor @Suite(.serialized) final class R22ADiscoverOnlyTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "R22ADiscoverOnlyTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "R22ADiscoverOnlyTests.\(UUID().uuidString)"
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

    /// Signed in to the small Navidrome, with Aurral's "Discover Weekly" (4 songs, all the flow's) and "Trending Mix"
    /// (empty: just made). `lists` adds Navidrome playlists first.
    private func signedIn(lists: [String: (name: String, songs: [String])] = [:],
                          setUp: (StubAurral) -> Void = { _ in }) async throws -> AppModel {
        for (id, list) in lists { nav.lists[id] = list }
        nav.install(on: transport.navidrome)
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly"), .init(id: "flow-tm", name: "Trending Mix")])
        aurral.setJobs([
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", durationMs: 251_000),
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Words"),
            .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000),
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Halo"),
        ])
        setUp(aurral)
        let model = makeModel()
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                          password: StubAurral.defaultPassword)
        return model
    }

    /// Where the phone and the car list playlists, by id: Library › Playlists (All and Yours), Home's shelf, Add to
    /// playlist / Save to playlist, and the car's Playlists.
    private func listed(_ model: AppModel) async throws -> [String: Set<String>] {
        let library = try await model.libraryPlaylists()
        let user = model.session?.username ?? ""
        return [
            "library": Set(library.map(\.id)),
            "yours": Set(AppModel.shown(library, .yours, user: user).map(\.id)),
            "home": Set(AppModel.homePlaylists(try await model.request { try await $0.playlists() }, username: user,
                                               isDiscover: model.isDiscoverPlaylist).map(\.id)),
            "pickers": Set(try await model.editablePlaylists().map(\.id)),
            "car": Set(try await CarPlayLibraryAdapter(model: model).playlists().map(\.id)),
        ]
    }

    private func expectOnlyInDiscover(_ id: String, _ model: AppModel, _ why: Comment,
                                      sourceLocation: SourceLocation = #_sourceLocation) async throws {
        #expect(model.isDiscoverPlaylist(id: id), why, sourceLocation: sourceLocation)
        #expect(try await model.discoverPlaylists().contains { $0.id == id }, "listed under Discover", sourceLocation: sourceLocation)
        for (place, ids) in try await listed(model) {
            #expect(!ids.contains(id), "not in \(place): \(why)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Gap 1: every one of the user's Aurral playlists, not only Add flow's

    /// D183 (supersedes D94's "only Add flow's"): a Spotify import, a YouTube import and a playlist made by hand in
    /// Aurral are Aurral's playlists too: Discover only, never Playlists.
    @Test func everySharedPlaylistIsDiscovers() async throws {
        let model = try await signedIn(lists: ["pl-sp": ("Summer Spotify", ["a-old"]), "pl-hand": ("jordan picks", [])]) { aurral in
            aurral.addSharedPlaylist(id: "sp-1", name: "Summer Spotify", provider: "spotify-playlist",
                                     songs: [(title: "Old", artist: "Low", durationMs: 300_000)])
            aurral.addSharedPlaylist(id: "hand-1", name: "jordan picks", provider: nil, songs: [])
        }
        defer { model.signOut() }
        try await expectOnlyInDiscover("pl-sp", model, "a Spotify import is Aurral's")
        try await expectOnlyInDiscover("pl-hand", model, "one made by hand in Aurral is Aurral's")
        #expect(model.discoverFlow(playlistId: "pl-sp") == nil, "never Refresh Flow: Aurral syncs it itself")
    }

    // MARK: - Gap 2: named as Aurral's is enough without proof it's the owner's own

    /// D182: a flow just made (its playlist still empty) and one still downloading (one song of four in) are
    /// Discover's; the owner's own same-named playlist, holding only their own songs, stays theirs.
    @Test func newAndDownloadingFlowsAreDiscovers() async throws {
        let model = try await signedIn(lists: ["pl-dw": ("Discover Weekly", ["a-lullaby"])])
        defer { model.signOut() }
        try await expectOnlyInDiscover("pl-empty", model, "Trending Mix, just made and empty")
        try await expectOnlyInDiscover("pl-dw", model, "Discover Weekly, one of its songs in so far")
        #expect(!model.isDiscoverPlaylist(id: "pl-mine"), "the owner's own Discover Weekly (none of Aurral's songs)")
        #expect(try await listed(model)["library"]?.contains("pl-mine") == true)
        #expect(!model.isDiscoverPlaylist(id: "pl-road"), "Road trip is no flow's name")
    }

    /// No proof without Aurral's song list: a same-named playlist stays Discover's while Aurral can't say.
    @Test func noJobsNoProof() async throws {
        let model = try await signedIn { $0.setJobsRoute(false) }
        defer { model.signOut() }
        #expect(model.isDiscoverPlaylist(id: "pl-mine"), "nothing proves it the owner's")
    }

    // MARK: - Gap 3: every name Aurral gives a playlist

    /// D181: Aurral's older names and a playlist file's name.
    @Test func everyNameAurralGives() async throws {
        let model = try await signedIn(lists: ["pl-legacy": ("[A] Trending Mix", ["a-words"]),
                                               "pl-file": ("\(StubAurral.defaultUsername) - Rock_Pop", [])]) { aurral in
            aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly"), .init(id: "flow-tm", name: "Trending Mix"),
                             .init(id: "flow-rp", name: "Rock/Pop")])
        }
        defer { model.signOut() }
        try await expectOnlyInDiscover("pl-legacy", model, "an older name")
        try await expectOnlyInDiscover("pl-file", model, "the playlist file's name")
    }

    // MARK: - Aurral's other users

    /// D184: Aurral shows an admin every user's flows; another user's playlist on this server is Aurral's too (Discover,
    /// no Refresh Flow), and that user's flows still aren't this user's own (D72).
    @Test func anotherUsersFlowIsDiscoversWithoutRefresh() async throws {
        let model = try await signedIn(lists: ["pl-sam": ("sam - Late Night", ["a-old"])]) { aurral in
            aurral.addUser(id: 2, username: "sam", password: "sam-pw")
            aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly"), .init(id: "flow-tm", name: "Trending Mix"),
                             .init(id: "flow-sam", name: "Late Night", ownerUserId: 2)])
        }
        defer { model.signOut() }
        #expect(model.discover.status?.flows.map(\.id) == ["flow-dw", "flow-tm"], "Your flows stay yours")
        // Round 23 R23F (D189 amends D184): listed under Discover only with "Show everyone's flows" on.
        #expect(try await !model.discoverPlaylists().contains { $0.id == "pl-sam" }, "only your own by default")
        model.showEveryonesFlows = true
        try await expectOnlyInDiscover("pl-sam", model, "Sam's flow's playlist")
        #expect(model.discoverFlow(playlistId: "pl-sam") == nil, "never Refresh someone else's flow")
    }

    // MARK: - Gap 4: before Aurral answers, and offline

    /// D57/D185: the ids saved for the account keep Aurral's playlists out at launch while Aurral can't be reached,
    /// and offline the car's Playlists (downloaded playlists) leaves them out too.
    @Test func savedIdsKeepThemOutBeforeAurralAnswersAndOffline() async throws {
        let first = try await signedIn()
        #expect(first.isDiscoverPlaylist(id: "pl-empty") && first.isDiscoverPlaylist(id: "pl-dw"))
        // A downloaded Discover playlist and a downloaded own one.
        let lullaby = Song(id: "a-lullaby", title: "Lullaby", artist: "Low", album: "A", albumId: "al-a", duration: 251)
        let x = Song(id: "m-x", title: "X", artist: "Q", album: "A", albumId: "al-m", duration: 100)
        first.download([lullaby], reason: .playlist("pl-dw"),
                       playlist: DownloadedPlaylist(id: "pl-dw", name: "Discover Weekly", coverArtId: nil,
                                                    songIds: ["a-lullaby"], savedAt: .now))
        first.download([x], reason: .playlist("pl-road"),
                       playlist: DownloadedPlaylist(id: "pl-road", name: "Road trip", coverArtId: nil, songIds: ["m-x"],
                                                    savedAt: .now))
        await first.downloads?.settled()
        first.updatePreferences { $0.downloads.offlineMode = .on }
        let offline = Set(try await CarPlayLibraryAdapter(model: first).playlists().map(\.id))
        #expect(offline.contains("pl-road") && !offline.contains("pl-dw"), "offline, the car's Playlists: \(offline)")
        first.updatePreferences { $0.downloads.offlineMode = .off }
        // As after a relaunch (nothing read this session), with Aurral out of reach.
        first.discover.forgetReads()
        aurral.setDown(true)
        await first.refreshDiscover(force: true)
        for id in ["pl-empty", "pl-dw"] {
            #expect(first.isDiscoverPlaylist(id: id), "\(id): saved for the account")
            #expect(try await !first.libraryPlaylists().contains { $0.id == id })
        }
        first.signOut()
    }

    // MARK: - Gap 5: without Aurral, ordinary playlists again

    /// D75 unchanged: Aurral disconnected, its playlists are ordinary playlists again.
    @Test func disconnectedTheyAreOrdinary() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.isDiscoverPlaylist(id: "pl-empty"))
        model.disconnectAurral()
        #expect(!model.isDiscoverPlaylist(id: "pl-empty") && !model.isDiscoverPlaylist(id: "pl-dw"))
        let library = try await model.libraryPlaylists().map(\.id)
        #expect(library.contains("pl-empty") && library.contains("pl-dw"))
    }

    // MARK: - D186: a new flow's songs start by themselves

    /// Aurral's writes to its data (its own login and logout aside).
    private var aurralWrites: [String] { aurral.asked.filter { $0.hasPrefix("POST") && !$0.hasPrefix("POST /api/auth/") } }

    /// A flow Aurral doesn't download by itself (`autoDownload` false), as Aurral 2.13 lists it.
    private func manualFlow(_ id: String, _ name: String) -> StubAurral.Flow {
        var flow = StubAurral.Flow(id: id, name: name)
        flow.autoDownload = false
        return flow
    }

    private let baseFlows: [StubAurral.Flow] = [.init(id: "flow-dw", name: "Discover Weekly"),
                                                .init(id: "flow-tm", name: "Trending Mix")]

    /// The first read only records what is there; a new flow Aurral won't download by itself gets "Download songs"
    /// once, in the background; one that downloads by itself and a new Aurral playlist get nothing (Aurral queues
    /// those itself); reading again never sends it twice.
    @Test func aNewFlowsSongsStartOnce() async throws {
        let model = try await signedIn { aurral in
            aurral.useAurral213()
            aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly"), self.manualFlow("flow-tm", "Trending Mix")])
        }
        defer { model.signOut() }
        #expect(aurralWrites.isEmpty, "the flows already there aren't started")
        #expect(model.handledAurralFlows == ["flow-dw", "flow-tm"])
        aurral.setFlows(baseFlows + [manualFlow("flow-new", "Night Drive"), .init(id: "flow-self", name: "Self Starter")])
        aurral.addSharedPlaylist(id: "sp-new", name: "Summer Spotify", provider: "spotify-playlist", songs: [])
        await model.refreshDiscover(force: true)
        #expect(await eventually { self.aurralWrites == ["POST /api/playlists/flows/flow-new/download"] }, "\(aurralWrites)")
        #expect(model.handledAurralFlows?.isSuperset(of: ["flow-new", "flow-self", "sp-new"]) == true)
        await model.refreshDiscover(force: true)
        await model.refreshDiscover(force: true)
        #expect(aurralWrites == ["POST /api/playlists/flows/flow-new/download"], "never twice")
    }

    /// Never while a run is under way: the flow is looked at again once the run is over.
    @Test func notWhileARunIsUnderWay() async throws {
        let model = try await signedIn { $0.useAurral213() }
        defer { model.signOut() }
        aurral.setFlows(baseFlows + [manualFlow("flow-new", "Night Drive")])
        aurral.setRunning("flow-new", true)
        await model.refreshDiscover(force: true)
        #expect(aurralWrites.isEmpty && model.handledAurralFlows?.contains("flow-new") == false)
        aurral.finishRun()
        await model.refreshDiscover(force: true)
        #expect(await eventually { self.aurralWrites == ["POST /api/playlists/flows/flow-new/download"] }, "\(aurralWrites)")
    }

    /// The switch off, or no downloader known: recorded, nothing sent. Aurral answering "no downloader" (409): a
    /// quiet note on the flow's page, never sent again.
    @Test func switchOffNoDownloaderAndTheNote() async throws {
        let model = try await signedIn { $0.useAurral213() }
        defer { model.signOut() }
        #expect(model.autoDownloadNewFlows, "on by default")
        model.autoDownloadNewFlows = false
        aurral.setFlows(baseFlows + [manualFlow("flow-off", "Off Flow")])
        await model.refreshDiscover(force: true)
        #expect(aurralWrites.isEmpty && model.handledAurralFlows?.contains("flow-off") == true)
        model.autoDownloadNewFlows = true
        aurral.setDownloadSources(configured: false)   // the bootstrap read at sign-in still says there is one
        aurral.setFlows(baseFlows + [manualFlow("flow-off", "Off Flow"), manualFlow("flow-409", "No Source")])
        await model.refreshDiscover(force: true)
        #expect(await eventually { model.autoDownloadNote(flowId: "flow-409") == .noDownloader })
        #expect(AurralAutoDownloadCopy.note(.noDownloader).contains("no downloader"))
        await model.refreshDiscover(force: true)
        #expect(aurralWrites == ["POST /api/playlists/flows/flow-409/download"], "sent once")
        await model.refreshAurralCapabilities(force: true)   // now known: none
        aurral.setFlows(baseFlows + [manualFlow("flow-none", "Still None")])
        await model.refreshDiscover(force: true)
        #expect(aurralWrites.count == 1, "no downloader known: nothing sent")
    }

    // MARK: - D187: Discover groups flows and Aurral's playlists

    /// One list: a flow's playlist and an Aurral playlist side by side, on the phone and in the car.
    @Test func discoverGroupsFlowsAndPlaylists() async throws {
        let model = try await signedIn(lists: ["pl-sp": ("Summer Spotify", ["a-old"])]) { aurral in
            aurral.addSharedPlaylist(id: "sp-1", name: "Summer Spotify", provider: "spotify-playlist",
                                     songs: [(title: "Old", artist: "Low", durationMs: 300_000)])
        }
        defer { model.signOut() }
        let phone = try await model.discoverPlaylists().map(\.id)
        #expect(phone.contains("pl-dw") && phone.contains("pl-sp"), "\(phone)")
        #expect(try await CarPlayLibraryAdapter(model: model).discoverPlaylists().map(\.id) == phone)
    }

    // MARK: - D188: Show Discover playlists in Playlists

    /// Off by default: Discover's are left out of Playlists. On: they're in Library › Playlists (All) and the car's
    /// Playlists too, still read-only, never in Yours or the add sheets, still under Discover; saved per account.
    @Test func showDiscoverPlaylistsInPlaylists() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(!model.showDiscoverInPlaylists, "off by default")
        #expect(try await !model.libraryPlaylists().contains { $0.id == "pl-dw" })
        model.showDiscoverInPlaylists = true
        let library = try await model.libraryPlaylists()
        #expect(library.contains { $0.id == "pl-dw" } && library.contains { $0.id == "pl-empty" })
        let user = model.session?.username ?? ""
        #expect(!AppModel.shown(library, .yours, user: user, isDiscover: model.isDiscoverPlaylist).contains { $0.id == "pl-dw" },
                "never Yours")
        #expect(try await CarPlayLibraryAdapter(model: model).playlists().contains { $0.id == "pl-dw" })
        #expect(try await !model.editablePlaylists().contains { $0.id == "pl-dw" }, "never in the add sheets")
        #expect(!model.canEdit(try #require(library.first { $0.id == "pl-dw" })), "read-only")
        #expect(try await model.discoverPlaylists().contains { $0.id == "pl-dw" }, "still under Discover")
        let scope = try #require(model.navidromeScope)
        #expect(defaults.bool(forKey: AppModel.showDiscoverInPlaylistsKeyPrefix + scope))
        #expect(AurralAutoDownloadCopy.showInPlaylists == "Show Discover playlists in Playlists")
    }
}
