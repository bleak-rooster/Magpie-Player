import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

/// Round 26 L (owner, 2026-11-11): "Also the changes for picking up the aurral flow/playlist with the same name under
/// different users (two separate flows/playlists) still doesn't work." Their setup: an Aurral admin; two Aurral shared
/// playlists with one name and different owners; "These are both only in Aurral, they are not present in Navidrome."
/// Build 27: "when I see everyone's I see the playlist twice without any usernames underneath and when I want to see
/// mine, I don't see it at all." Wanted: only mine shows mine; everyone's shows both, the other user's name under
/// theirs (D271–D275). Against the stub Aurral and a mock Navidrome, never the owner's.
@MainActor @Suite(.serialized) final class R26LSameNameNotInNavidromeTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "R26LSameNameTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "R26LSameNameTests.\(UUID().uuidString)"
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

    enum Kind { case playlists, flows }
    /// What Navidrome has for the two items: no playlist of the name, or two empty playlists of the name (what Aurral
    /// 2.13 publishes for a playlist whose songs aren't in yet).
    enum InNavidrome: Sendable { case nothing, twoEmpty }

    static let jordanPassword = "jordan-pw"

    /// Jordan (signed in to Aurral; an admin, or not) and Sam each have a "Chill". Jordan's songs: Lullaby, Words;
    /// Sam's: Unknown Song, Halo. `downloading`: Jordan's are still downloading (none in the library yet).
    private func signedIn(_ kind: Kind, admin: Bool, navidrome: InNavidrome, downloading: Bool = false) async throws -> AppModel {
        switch navidrome {
        case .nothing: nav.lists = ["pl-road": ("Road trip", ["m-x", "m-y"])]
        case .twoEmpty: nav.lists = ["pl-e1": ("Chill", []), "pl-e2": ("Chill", []), "pl-road": ("Road trip", ["m-x", "m-y"])]
        }
        nav.install(on: transport.navidrome)
        aurral.useAurral213()
        aurral.addUser(id: 3, username: "jordan", password: Self.jordanPassword, role: admin ? "admin" : "user")
        aurral.addUser(id: 2, username: "sam", password: "sam-pw")
        if !admin {
            aurral.setPermissions(AurralPermissions(accessFlow: true, addArtist: true, addAlbum: true), for: "jordan")
        }
        let mine: [(title: String, artist: String, durationMs: Int)] = [("Lullaby", "Low", 251_000), ("Words", "Low", 200_000)]
        let sams: [(title: String, artist: String, durationMs: Int)] = [("Unknown Song", "Nobody", 180_000), ("Halo", "Low", 0)]
        switch kind {
        case .playlists:
            aurral.addSharedPlaylist(id: "sp-j", name: "Chill", provider: nil, owner: 3, songs: mine)
            aurral.addSharedPlaylist(id: "sp-s", name: "Chill", provider: nil, owner: 2, songs: sams)
        case .flows:
            aurral.setFlows([.init(id: "flow-j", name: "Chill", ownerUserId: 3), .init(id: "flow-s", name: "Chill", ownerUserId: 2)])
            aurral.setJobs(mine.map { .init(flowId: "flow-j", artistName: $0.artist, trackName: $0.title, durationMs: $0.durationMs) }
                + sams.map { .init(flowId: "flow-s", artistName: $0.artist, trackName: $0.title, durationMs: $0.durationMs) })
        }
        if downloading {
            aurral.setJobStatus("job-0", "downloading")
            aurral.setJobStatus("job-1", "pending")
        }
        let model = makeModel()
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        _ = try await model.connectAurral(base: aurral.base, username: "jordan", password: Self.jordanPassword)
        await model.refreshDiscover(force: true)
        return model
    }

    /// Library › Discover's rows as (name, caption, Aurral item id or "playlist:<id>").
    private func rows(_ model: AppModel) async throws -> [Row] {
        try await model.discoverRows().map { row in
            let key: String = switch row.link {
            case .item(let item, _): item.id
            case .playlist(let playlist): "playlist:" + playlist.id
            }
            return Row(name: row.name, caption: model.discoverOwnerCaption(row: row), key: key)
        }
    }

    struct Row: Equatable, CustomStringConvertible {
        var name: String
        var caption: String?
        var key: String
        var description: String { "\(name)[\(caption ?? "-")](\(key))" }
    }

    private func carIds(_ model: AppModel) async throws -> [String] {
        try await CarPlayLibraryAdapter(model: model).discoverPlaylists().map(\.id)
    }

    /// The owner's words: only mine, the user's "Chill" once, no caption; everyone's, both, "sam" under Sam's. Never
    /// two rows for one item, never a row only a name ties to an owner.
    private func expectWanted(_ model: AppModel, mine: String, sams: String?) async throws {
        let only = try await rows(model)
        #expect(only == [Row(name: "Chill", caption: nil, key: mine)], "only mine: \(only)")
        let car = try await carIds(model)
        #expect(car.isEmpty, "the car lists only what plays: \(car)")
        model.showEveryonesFlows = true
        let all = try await rows(model)
        let wanted = [Row(name: "Chill", caption: nil, key: mine)] + (sams.map { [Row(name: "Chill", caption: "sam", key: $0)] } ?? [])
        #expect(all.sorted { $0.key < $1.key } == wanted.sorted { $0.key < $1.key }, "everyone's: \(all)")
        let carAll = try await carIds(model)
        #expect(carAll.isEmpty, "everyone's in the car: \(carAll)")
    }

    // MARK: - The owner's setup, reproduced

    @Test func playlists_admin_notInNavidrome() async throws {
        let model = try await signedIn(.playlists, admin: true, navidrome: .nothing)
        defer { model.signOut() }
        try await expectWanted(model, mine: "sp-j", sams: "sp-s")
    }

    /// Build 27's symptom exactly: Navidrome holds two empty "Chill" playlists (Aurral's, songs not in yet).
    @Test func playlists_admin_twoEmptyInNavidrome() async throws {
        let model = try await signedIn(.playlists, admin: true, navidrome: .twoEmpty)
        defer { model.signOut() }
        try await expectWanted(model, mine: "sp-j", sams: "sp-s")
    }

    @Test func playlists_admin_mineDownloading_notInNavidrome() async throws {
        let model = try await signedIn(.playlists, admin: true, navidrome: .nothing, downloading: true)
        defer { model.signOut() }
        try await expectWanted(model, mine: "sp-j", sams: "sp-s")
    }

    /// A user who isn't an admin is shown only their own items (2.13's getStaticPlaylistsForUser): only mine still
    /// shows theirs, and everyone's adds nothing (Sam's is invisible to them).
    @Test(arguments: [InNavidrome.nothing, .twoEmpty]) func playlists_notAdmin(_ navidrome: InNavidrome) async throws {
        let model = try await signedIn(.playlists, admin: false, navidrome: navidrome)
        defer { model.signOut() }
        try await expectWanted(model, mine: "sp-j", sams: nil)
    }

    // MARK: - Flows

    /// Two same-named flows, neither in Navidrome: the user's own is Your flows' row (round 16, never a second one
    /// here); Sam's is a row of its own under everyone's, "sam" under it.
    @Test(arguments: [InNavidrome.nothing, .twoEmpty]) func flows_admin(_ navidrome: InNavidrome) async throws {
        let model = try await signedIn(.flows, admin: true, navidrome: navidrome)
        defer { model.signOut() }
        #expect(model.aurralCanManageFlows)
        #expect(model.unpublishedRecipeFlows.map(\.id) == ["flow-j"])
        #expect(try await rows(model).isEmpty)
        model.showEveryonesFlows = true
        #expect(try await rows(model) == [Row(name: "Chill", caption: "sam", key: "flow-s")])
        #expect(try await carIds(model).isEmpty)
    }

    /// Without Your flows (an Aurral without flow management, 2.10), the user's own flow is a row here instead.
    @Test func flows_admin_noFlowManagement() async throws {
        let model = try await signedIn(.flows, admin: true, navidrome: .nothing)
        defer { model.signOut() }
        aurral.setFeatures(nil)
        aurral.setVersion("2.10.0")
        await model.refreshAurralCapabilities(force: true)
        await model.refreshDiscover(force: true)
        #expect(!model.aurralCanManageFlows)
        try await expectWanted(model, mine: "flow-j", sams: "flow-s")
    }

    // MARK: - What stays as it was

    /// The item's state, said beside a symbol: the user's own with songs on the way, how far; otherwise not ready yet.
    @Test func itemState_downloadingThenNotReady() async throws {
        let model = try await signedIn(.playlists, admin: true, navidrome: .nothing, downloading: true)
        defer { model.signOut() }
        let jordans = try #require(model.discover.itemRows.first { $0.item.id == "sp-j" })
        #expect(model.discoverItemState(jordans.item, mine: true).text == DiscoverPagesCopy.downloading(0, 2))
        let sams = try #require(model.discover.itemRows.first { $0.item.id == "sp-s" })
        #expect(model.discoverItemState(sams.item, mine: false) == (DiscoverPagesCopy.notReady, "clock"))
    }

    /// The two empty playlists are never rows, but they are still Aurral's: never in Playlists (D182, D189).
    @Test func emptyUnclaimed_stillOutOfPlaylists() async throws {
        let model = try await signedIn(.playlists, admin: true, navidrome: .twoEmpty)
        defer { model.signOut() }
        #expect(model.isDiscoverPlaylist(id: "pl-e1") && model.isDiscoverPlaylist(id: "pl-e2"))
        model.showEveryonesFlows = true
        #expect(!(try await model.discoverPlaylists().map(\.id)).contains("pl-e1"))
    }

    /// Once songs are in, each playlist proves itself (D203) and is its item's row: the item never shows twice.
    @Test func songsArrive_playlistIsTheRow() async throws {
        let model = try await signedIn(.playlists, admin: true, navidrome: .twoEmpty)
        defer { model.signOut() }
        nav.lists["pl-e1"] = ("Chill", ["a-lullaby", "a-words"])
        nav.lists["pl-e2"] = ("Chill", ["a-other", "a-nameonly"])
        await model.refreshDiscover(force: true)
        #expect(try await rows(model) == [Row(name: "Chill", caption: nil, key: "playlist:pl-e1")])
        model.showEveryonesFlows = true
        #expect(try await rows(model).sorted { $0.key < $1.key }
                    == [Row(name: "Chill", caption: nil, key: "playlist:pl-e1"), Row(name: "Chill", caption: "sam", key: "playlist:pl-e2")])
    }

    /// D202's Q1 is kept where a playlist has songs nothing can tie to an owner: it stays a row with no caption, and
    /// the items it may be don't get a second one.
    @Test func unprovenWithSongs_staysQ1_noSecondRow() async throws {
        let model = try await signedIn(.playlists, admin: true, navidrome: .twoEmpty)
        defer { model.signOut() }
        nav.lists["pl-e1"] = ("Chill", ["a-old"])   // one of Aurral's copies, neither item's
        nav.lists["pl-e2"] = ("Chill", ["a-old"])
        await model.refreshDiscover(force: true)
        #expect(try await rows(model).isEmpty)
        model.showEveryonesFlows = true
        #expect(try await rows(model).sorted { $0.key < $1.key }
                    == [Row(name: "Chill", caption: nil, key: "playlist:pl-e1"), Row(name: "Chill", caption: nil, key: "playlist:pl-e2")])
    }

    /// Sign-out forgets the rows with everything else read for the account.
    @Test func signOut_forgetsItemRows() async throws {
        let model = try await signedIn(.playlists, admin: true, navidrome: .twoEmpty)
        #expect(model.discover.itemRows.count == 2 && model.discover.hiddenPlaylistIds == ["pl-e1", "pl-e2"])
        model.signOut()
        #expect(model.discover.itemRows.isEmpty && model.discover.hiddenPlaylistIds.isEmpty)
    }

    /// Reads only: nothing is sent to Aurral for any of this.
    @Test func readsOnly() async throws {
        let model = try await signedIn(.playlists, admin: true, navidrome: .twoEmpty)
        defer { model.signOut() }
        model.showEveryonesFlows = true
        _ = try await rows(model)
        let writes = aurral.asked.filter { !$0.hasPrefix("GET ") && !$0.hasSuffix("/api/auth/login") }
        #expect(writes.isEmpty, "\(writes)")
    }
}
