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
}
