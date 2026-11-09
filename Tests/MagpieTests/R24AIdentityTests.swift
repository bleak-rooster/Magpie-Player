import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

/// Round 24 (owner, 2026-11-08): "Aurral playlists/flows that share a name across two users both appear even with
/// only-mine selected; tie them to users by identity, not by name", and "when showing everyone's playlists/flows, show
/// the owner's username subtly near the name" (D202–D205). Against the stub Aurral and a mock Navidrome, never the
/// owner's.
@MainActor @Suite(.serialized) final class R24AIdentityTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "R24AIdentityTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "R24AIdentityTests.\(UUID().uuidString)"
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

    /// Aurral's prefix off: the signed-in user's "Chill" and Sam's "Chill" give two Navidrome playlists both called
    /// "Chill": pl-c1 holds the user's songs, pl-c2 Sam's. `sameSongs`: both hold the same songs (a tie).
    private func signedIn(sameSongs: Bool = false, before: (AppModel) -> Void = { _ in }) async throws -> AppModel {
        nav.lists = [
            "pl-c1": ("Chill", ["a-lullaby", "a-words"]),
            "pl-c2": ("Chill", sameSongs ? ["a-lullaby", "a-words"] : ["a-other", "a-nameonly"]),
            "pl-road": ("Road trip", ["m-x", "m-y"]),
        ]
        nav.install(on: transport.navidrome)
        aurral.useAurral213()
        aurral.addUser(id: 2, username: "sam", password: "sam-pw")
        aurral.setFlows([.init(id: "flow-c", name: "Chill"), .init(id: "flow-sc", name: "Chill", ownerUserId: 2)])
        let samJobs: [StubAurral.Job] = sameSongs
            ? [.init(flowId: "flow-sc", artistName: "Low", trackName: "Lullaby", durationMs: 251_000),
               .init(flowId: "flow-sc", artistName: "Low", trackName: "Words", durationMs: 200_000)]
            : [.init(flowId: "flow-sc", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000),
               .init(flowId: "flow-sc", artistName: "Low", trackName: "Halo")]
        aurral.setJobs([.init(flowId: "flow-c", artistName: "Low", trackName: "Lullaby", durationMs: 251_000),
                        .init(flowId: "flow-c", artistName: "Low", trackName: "Words", durationMs: 200_000)] + samJobs)
        let model = makeModel()
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        before(model)
        _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                          password: StubAurral.defaultPassword)
        await model.refreshDiscover(force: true)
        return model
    }

    private func inPlaylists(_ model: AppModel) async throws -> Set<String> {
        let library = try await model.libraryPlaylists()
        let car = try await CarPlayLibraryAdapter(model: model).playlists()
        return Set(library.map(\.id)).union(car.map(\.id))
    }

    private func inDiscover(_ model: AppModel) async throws -> (phone: [String], car: [String]) {
        (try await model.discoverPlaylists().map(\.id), try await CarPlayLibraryAdapter(model: model).discoverPlaylists().map(\.id))
    }

    /// D202: "only mine" (the default) lists the user's own "Chill" and not Sam's, though both carry the same name.
    @Test func onlyMine_showsOneOfTwoSameNamed() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let discover = try await inDiscover(model)
        #expect(discover.phone == ["pl-c1"], "\(discover.phone)")
        #expect(discover.car == discover.phone)
        #expect(model.discoverFlow(playlistId: "pl-c1")?.id == "flow-c", "the user's own: Refresh Flow")
        #expect(model.discoverFlow(playlistId: "pl-c2") == nil, "never Refresh someone else's")
    }

    /// D205: everyone's on: both, each row with its owner under the name (Sam's), nothing for the user's own.
    @Test func everyones_showsBothWithOwnerNames() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.discoverOwnerCaption(playlistId: "pl-c2") == nil, "only while everyone's are shown")
        model.showEveryonesFlows = true
        let discover = try await inDiscover(model)
        #expect(Set(discover.phone) == ["pl-c1", "pl-c2"], "\(discover.phone)")
        #expect(model.discoverOwnerCaption(playlistId: "pl-c2") == "sam")
        #expect(model.discoverOwnerCaption(playlistId: "pl-c1") == nil, "your own: no caption")
        #expect(OwnerCaption.accessibilityText(owner: model.discoverOwnerCaption(playlistId: "pl-c2"),
                                               signedInUser: nil) == "made by sam")
    }

    /// D189 unchanged: neither is ever in Playlists; with "Show Discover playlists in Playlists" on, only the user's own.
    @Test func playlistsList_neverShowsClaimedPlaylist() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let playlists = try await inPlaylists(model)
        #expect(!playlists.contains("pl-c1") && !playlists.contains("pl-c2") && playlists.contains("pl-road"), "\(playlists)")
        model.showDiscoverInPlaylists = true
        model.showEveryonesFlows = true
        let shown = try await inPlaylists(model)
        #expect(shown.contains("pl-c1") && !shown.contains("pl-c2"), "\(shown)")
    }

    /// Q1: a tie the songs can't break claims neither: both stay Aurral's (out of Playlists), shown only under
    /// everyone's, with no owner and no Refresh Flow: never a wrong owner.
    @Test func tie_showsNeitherAsYours() async throws {
        let model = try await signedIn(sameSongs: true)
        defer { model.signOut() }
        #expect(try await inDiscover(model).phone.isEmpty)
        #expect(model.isDiscoverPlaylist(id: "pl-c1") && model.isDiscoverPlaylist(id: "pl-c2"))
        #expect(try await inPlaylists(model).isDisjoint(with: ["pl-c1", "pl-c2"]))
        model.showEveryonesFlows = true
        #expect(Set(try await inDiscover(model).phone) == ["pl-c1", "pl-c2"])
        #expect(model.discoverOwnerCaption(playlistId: "pl-c1") == nil && model.discoverOwnerCaption(playlistId: "pl-c2") == nil)
        #expect(model.discoverFlow(playlistId: "pl-c1") == nil && model.discoverFlow(playlistId: "pl-c2") == nil)
    }

    /// D204: the claims are saved per account by Aurral item, and kept before Aurral answers.
    @Test func savedClaimsPerItem() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let scope = try #require(model.navidromeScope)
        let saved = defaults.dictionary(forKey: AppModel.discoverClaimsKey(scope)) as? [String: String]
        #expect(saved == ["flow-c": "pl-c1", "flow-sc": "pl-c2"])
        model.discover.forgetReads()
        aurral.setDown(true)
        await model.refreshDiscover(force: true)
        #expect(try await model.discoverPlaylists().map(\.id) == ["pl-c1"], "Sam's stays out before Aurral answers")
    }

    /// D204's upgrade: an old saved id (round 23's id set, no item) is kept only while exactly one Aurral item can claim
    /// it. "Chill" fits two items, so the old "pl-c1" isn't handed to the user's flow: with songs that can't tell the
    /// two apart, neither is the user's.
    @Test func savedIds_migrateKeepsOnlyUnambiguous() async throws {
        let model = try await signedIn(sameSongs: true)
        defer { model.signOut() }
        let scope = try #require(model.navidromeScope)
        defaults.removeObject(forKey: AppModel.discoverClaimsKey(scope))   // as saved by round 23
        defaults.set(["pl-c1", "pl-c2"], forKey: AppModel.discoverPlaylistsKey(scope))
        await model.refreshDiscover(force: true)
        #expect(defaults.dictionary(forKey: AppModel.discoverClaimsKey(scope)) as? [String: String] == [:])
        #expect(try await model.discoverPlaylists().isEmpty)
        #expect(model.isDiscoverPlaylist(id: "pl-c1") && model.isDiscoverPlaylist(id: "pl-c2"), "still Aurral's")
    }

    /// Sign-out forgets the claims with the other Discover keys.
    @Test func signOutForgetsClaims() async throws {
        let model = try await signedIn()
        model.signOut()
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(AppModel.discoverClaimsKeyPrefix) })
    }
}
