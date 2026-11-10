import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

/// Round 25 (owner, 2026-11-10): "There is one playlist with the same name in two separate users, and when I set it so
/// that only playlists/flows specific to me are meant to show, this playlist does not show at all. When I want to see
/// all playlists, then this playlist comes up twice without the name of the other user underneath either one."
/// (D251–D253). Aurral's owner prefix is off, so both Navidrome playlists are called "Chill". Unique names were never
/// affected: a name only one item carries is claimed by name (D203 step 4); a shared name needs the songs (step 3),
/// and those came only from Aurral's general jobs list, which doesn't always hold an item's songs. Against the stub
/// Aurral and a mock Navidrome, never the owner's.
@MainActor @Suite(.serialized) final class R25JSameNameTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "R25JSameNameTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "R25JSameNameTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = AurralRouting()
    let nav = DiscoverNavidrome()
    var aurral: StubAurral { transport.aurral }

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                 aurralStore: MemoryAurralStore(), matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                 probeTransport: transport, engine: FakeEngine(), defaults: defaults, systemNowPlaying: false,
                 notifications: false, network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
    }

    enum Kind { case flows, playlists }
    enum Gap { case listUnreadable, libraryReferences }

    /// The signed-in user's "Chill" (pl-c1: Lullaby, Words) and Sam's "Chill" (pl-c2: Unknown Song, Halo), as flows or
    /// as Aurral playlists. `admin`: the user is an Aurral admin (shown Sam's items) or not (shown only their own, as
    /// 2.13's getFlowsForUser and getStaticPlaylistsForUser do). `gap`: why the general jobs list holds neither item's
    /// songs: it couldn't be read (an Aurral whose list is over D115's 8 MB cap reads as none, as a 404 does), or the
    /// playlists' songs are references to Library jobs (2.13 lists those under "library" there).
    private func signedIn(_ kind: Kind, admin: Bool, gap: Gap, extra: (StubAurral) -> Void = { _ in }) async throws -> AppModel {
        nav.lists = [
            "pl-c1": ("Chill", ["a-lullaby", "a-words"]),
            "pl-c2": ("Chill", ["a-other", "a-nameonly"]),
            "pl-road": ("Road trip", ["m-x", "m-y"]),
        ]
        nav.install(on: transport.navidrome)
        aurral.useAurral213()
        aurral.addUser(id: 2, username: "sam", password: "sam-pw")
        let mine: [(title: String, artist: String, durationMs: Int)] = [("Lullaby", "Low", 251_000), ("Words", "Low", 200_000)]
        let sams: [(title: String, artist: String, durationMs: Int)] = [("Unknown Song", "Nobody", 180_000), ("Halo", "Low", 0)]
        switch kind {
        case .flows:
            aurral.setFlows([.init(id: "flow-c", name: "Chill"), .init(id: "flow-sc", name: "Chill", ownerUserId: 2)])
            aurral.setJobs(mine.map { .init(flowId: "flow-c", artistName: $0.artist, trackName: $0.title, durationMs: $0.durationMs) }
                + sams.map { .init(flowId: "flow-sc", artistName: $0.artist, trackName: $0.title, durationMs: $0.durationMs) })
        case .playlists:
            aurral.addSharedPlaylist(id: "sp-c", name: "Chill", provider: nil, owner: 1, songs: mine)
            aurral.addSharedPlaylist(id: "sp-sc", name: "Chill", provider: nil, owner: 2, songs: sams)
        }
        switch gap {
        case .listUnreadable: aurral.setJobsRoute(false)
        case .libraryReferences:
            for id in ["sp-c", "sp-sc"] { aurral.referenceLibrarySongs(playlistId: id) }
        }
        if !admin {
            aurral.setRole("user", for: StubAurral.defaultUsername)
            aurral.setPermissions(AurralPermissions(accessFlow: true, addArtist: true, addAlbum: true),
                                  for: StubAurral.defaultUsername)
        }
        extra(aurral)
        let model = makeModel()
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                          password: StubAurral.defaultPassword)
        await model.refreshDiscover(force: true)
        return model
    }

    private func inDiscover(_ model: AppModel) async throws -> (phone: [String], car: [String]) {
        (try await model.discoverPlaylists().map(\.id), try await CarPlayLibraryAdapter(model: model).discoverPlaylists().map(\.id))
    }

    /// The owner's words, for each setup: "only mine" shows the user's "Chill" exactly once; "everyone's" shows both,
    /// Sam's with "sam" under it when Aurral named Sam's item to this user (an admin), with nothing under it when it
    /// didn't (never a guessed owner), and nothing under the user's own.
    private func expectOwnersOutcome(_ model: AppModel, admin: Bool, ownItem: String) async throws {
        let only = try await inDiscover(model)
        #expect(only.phone == ["pl-c1"], "only mine: \(only.phone)")
        #expect(only.car == only.phone)
        #expect(model.discover.playlists.first { $0.playlist.id == "pl-c1" }?.flow.id == ownItem, "the user's own item")
        #expect(model.discover.playlists.first { $0.playlist.id == "pl-c2" }?.flow.id == "", "never the user's")
        #expect(model.discoverFlow(playlistId: "pl-c2") == nil && model.searchAgainFlow(playlistId: "pl-c2") == nil)
        model.showEveryonesFlows = true
        let all = try await inDiscover(model)
        #expect(all.phone.sorted() == ["pl-c1", "pl-c2"], "everyone's: \(all.phone)")
        #expect(model.discoverOwnerCaption(playlistId: "pl-c1") == nil, "your own: no caption")
        #expect(model.discoverOwnerCaption(playlistId: "pl-c2") == (admin ? "sam" : nil))
    }

    // MARK: - The owner's symptom, reproduced

    @Test func flows_admin_jobsListUnreadable() async throws {
        let model = try await signedIn(.flows, admin: true, gap: .listUnreadable)
        defer { model.signOut() }
        try await expectOwnersOutcome(model, admin: true, ownItem: "flow-c")
    }

    @Test func flows_notAdmin_jobsListUnreadable() async throws {
        let model = try await signedIn(.flows, admin: false, gap: .listUnreadable)
        defer { model.signOut() }
        try await expectOwnersOutcome(model, admin: false, ownItem: "flow-c")
    }

    @Test func playlists_admin_libraryReferences() async throws {
        let model = try await signedIn(.playlists, admin: true, gap: .libraryReferences)
        defer { model.signOut() }
        try await expectOwnersOutcome(model, admin: true, ownItem: "sp-c")
    }

    @Test func playlists_notAdmin_libraryReferences() async throws {
        let model = try await signedIn(.playlists, admin: false, gap: .libraryReferences)
        defer { model.signOut() }
        try await expectOwnersOutcome(model, admin: false, ownItem: "sp-c")
    }
}
