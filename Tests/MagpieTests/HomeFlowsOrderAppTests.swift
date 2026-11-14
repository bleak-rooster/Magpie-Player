import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

/// Round 27 H (owner, 2026-11-14): "On the home screen of the app, there should be a switch in settings to present your
/// flows alphabetically or based on last played. You should also be able to choose if it presents all flows/playlists
/// regardless of user or just yours. If it includes other people's ones, then their username should be on it
/// somewhere." (D297–D299; Q3: one shared "everyone's" choice.) Against the stub Aurral and a mock Navidrome.
@MainActor @Suite(.serialized) final class HomeFlowsOrderAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "HomeFlowsOrderAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "HomeFlowsOrderAppTests.\(UUID().uuidString)"
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

    /// Signed in to the small Navidrome; with `aurral`, Aurral 2.13 too: the user's "Discover Weekly" (pl-dw) and
    /// "Trending Mix" (pl-empty), and Sam's "Late Night" (pl-sam, "sam - Late Night").
    private func signedIn(aurral connects: Bool = true) async throws -> AppModel {
        nav.lists["pl-sam"] = ("sam - Late Night", ["a-old"])
        nav.lists["pl-empty"] = ("Trending Mix", ["a-words"])
        nav.lists["pl-mine"] = nil   // no same-named playlist of the owner's: Discover Weekly is plainly the user's flow
        nav.install(on: transport.navidrome)
        aurral.useAurral213()
        aurral.addUser(id: 2, username: "sam", password: "sam-pw")
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly"), .init(id: "flow-tm", name: "Trending Mix"),
                         .init(id: "flow-sam", name: "Late Night", ownerUserId: 2)])
        aurral.setJobs([.init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", durationMs: 251_000),
                        .init(flowId: "flow-dw", artistName: "Low", trackName: "Words", status: "failed"),
                        .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000,
                              status: "saved"),
                        .init(flowId: "flow-dw", artistName: "Low", trackName: "Halo"),
                        .init(flowId: "flow-tm", artistName: "Low", trackName: "Words", durationMs: 200_000),
                        .init(flowId: "flow-sam", artistName: "Low", trackName: "Old", durationMs: 300_000)])
        let model = makeModel()
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if connects {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
            await model.refreshDiscover(force: true)
        }
        return model
    }

    /// The Discover playlists on Home's Your flows shelf, in its order.
    private func homeFlows(_ model: AppModel) async throws -> [String] {
        let shelf = try await model.homeShelves(for: [.discover]).first { $0.section == .discover }
        return (shelf?.items ?? []).compactMap { item in if case .playlist(let p) = item { p.id } else { nil } }
    }

    private func playlist(_ id: String, _ model: AppModel) async throws -> Playlist {
        try #require(try await model.request { try await $0.playlists() }.first { $0.id == id })
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - D297: plays recorded

    /// A flow's page (Play, Shuffle, a row) notes the play for the quick grid (`noteRecentlyPlayed`); a Discover
    /// playlist is now also recorded as a flow play. A playlist that isn't a flow is not.
    @Test func flowPlays_recordedFromPage() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.flowPlays.isEmpty)
        model.noteRecentlyPlayed(.playlist(try await playlist("pl-empty", model)))
        #expect(model.flowPlays.keys.sorted() == ["pl-empty"])
        model.noteRecentlyPlayed(.playlist(try await playlist("pl-road", model)))
        #expect(model.flowPlays["pl-road"] == nil, "the owner's own playlist isn't a flow")
        model.noteRecentlyPlayed(.album(Album(id: "al-1", name: "A", artist: "Q", songCount: 1, duration: 1)))
        #expect(model.flowPlays.count == 1)
    }

    /// The quick grid's long-press Play and Shuffle note the play through the same hook.
    @Test func flowPlays_recordedFromHomeTile() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let tile = RecentPlay(kind: .playlist, itemId: "pl-dw", title: "Discover Weekly", playedAt: nil)
        model.noteRecentlyPlayed(tile)
        #expect(model.flowPlays["pl-dw"] != nil)
    }

    /// At most 300 plays a account, the oldest dropped; saved in the Home folder (no backup); gone at sign-out.
    @Test func flowPlays_boundedAndRemovedAtSignOut() async throws {
        var plays: [String: Date] = [:]
        for i in 0..<320 { plays = FlowPlays.noting("p\(i)", at: t0.addingTimeInterval(Double(i)), in: plays) }
        #expect(plays.count == FlowPlays.limit && FlowPlays.limit == 300)
        #expect(plays["p0"] == nil && plays["p19"] == nil && plays["p20"] != nil && plays["p319"] != nil)
        let again = FlowPlays.noting("p20", at: t0.addingTimeInterval(1_000), in: plays)
        #expect(again.count == 300 && again["p20"] == t0.addingTimeInterval(1_000), "a replay moves it, nothing dropped")

        let model = try await signedIn()
        let scope = try #require(model.navidromeScope)
        model.noteFlowPlayed(playlistId: "pl-dw", at: t0)
        let file = FlowPlaysStore(root: tmp, scope: scope)
        #expect(file.url.deletingLastPathComponent() == HomeShelfCache.directory(root: tmp))
        #expect(file.load() == ["pl-dw": t0], "saved at once")
        #expect(try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // A file someone else wrote, too big, reads as nothing; one over the limit is cut to it.
        model.signOut()
        #expect(!FileManager.default.fileExists(atPath: file.url.path), "removed at sign-out")
        #expect(model.flowPlays.isEmpty)
        file.save(Dictionary(uniqueKeysWithValues: (0..<400).map { ("x\($0)", t0.addingTimeInterval(Double($0))) }))
        #expect(file.load().count == 300 && file.load()["x399"] != nil && file.load()["x0"] == nil)
    }

    // MARK: - D298: Your flows on Home

    @Test func phoneHome_lastPlayedDefault() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.preferences.layout.homeFlowsOrder == .lastPlayed)
        #expect(try await homeFlows(model) == ["pl-dw", "pl-empty"], "nothing played yet: A to Z")
        model.noteFlowPlayed(playlistId: "pl-empty", at: t0)
        #expect(try await homeFlows(model) == ["pl-empty", "pl-dw"], "the one played lately first")
        model.noteFlowPlayed(playlistId: "pl-dw", at: t0.addingTimeInterval(5))
        #expect(try await homeFlows(model) == ["pl-dw", "pl-empty"])
    }

    @Test func phoneHome_alphabetical() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.showEveryonesFlows = true
        model.noteFlowPlayed(playlistId: "pl-empty", at: t0)
        model.setHomeFlowsOrder(.alphabetical)
        #expect(model.preferences.layout.homeFlowsOrder == .alphabetical)
        #expect(try await homeFlows(model) == ["pl-dw", "pl-sam", "pl-empty"], "Discover Weekly, sam - Late Night, Trending Mix")
        model.setHomeFlowsOrder(.lastPlayed)
        #expect(try await homeFlows(model) == ["pl-empty", "pl-dw", "pl-sam"])
    }

    /// Library › Discover keeps the server's order (D187), whatever Home's order and plays.
    @Test func libraryDiscoverKeepsServerOrder() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.showEveryonesFlows = true
        let before = try await model.discoverPlaylists().map(\.id)
        model.noteFlowPlayed(playlistId: "pl-sam", at: t0)
        model.setHomeFlowsOrder(.alphabetical)
        #expect(try await model.discoverPlaylists().map(\.id) == before)
        #expect(before == ["pl-dw", "pl-empty", "pl-sam"])
    }

    // MARK: - D299: whose flow, on Home

    @Test func homeTile_captionOnlyForOthersWithEveryoneOn() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.homeFlowCaption(playlistId: "pl-sam") == nil, "everyone's off: never listed, never named")
        model.showEveryonesFlows = true
        #expect(model.homeFlowCaption(playlistId: "pl-sam") == "sam")
        #expect(model.homeFlowCaption(playlistId: "pl-dw") == nil, "your own")
        #expect(model.homeFlowCaption(playlistId: "pl-road") == nil, "not a flow")
        #expect(PlaylistTile.accessibilityLabel(name: "Late Night", subtitle: "Playlist \u{00B7} 1 song", owner: "sam")
                == "Late Night, made by sam, Playlist \u{00B7} 1 song", "the tile is one VoiceOver element")
        #expect(PlaylistTile.accessibilityLabel(name: "Road trip", subtitle: "Playlist \u{00B7} 4 songs", owner: nil)
                == "Road trip, Playlist \u{00B7} 4 songs", "as before")
    }

    // MARK: - Settings › Home & Library (D296, D298; Q3)

    @Test func settingsSectionHiddenWithoutAurral() async throws {
        let alone = try await signedIn(aurral: false)
        #expect(!HomeAndLibraryView.showsFlowsSection(alone))
        alone.signOut()
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(HomeAndLibraryView.showsFlowsSection(model))
        #expect(HomeFlowsCopy.section == "Your flows on Home")
        #expect(HomeFlowsCopy.order == "Order")
        #expect(HomeFlowsOrder.allCases.map(HomeFlowsCopy.title) == ["Last played", "A to Z"])
        #expect(HomeFlowsCopy.footer == "Flows you\u{2019}ve played lately come first; the rest follow A to Z.")
        #expect(EveryonesFlowsCopy.toggle == "Show everyone\u{2019}s flows and playlists", "D190's, unchanged (Q3)")
    }

    /// Navidrome alone (and with Lidarr: nothing here reads Lidarr): album covers only, no flows section, no flows on
    /// Home. With Aurral (alone or with Lidarr): all of it.
    @Test func fourSetups() async throws {
        let alone = try await signedIn(aurral: false)
        #expect(AlbumGrid.columnCount(width: 335, accessibility: false, size: .small) == 3)
        #expect(!HomeAndLibraryView.showsFlowsSection(alone))
        #expect(!alone.homeSections.contains(.discover))
        #expect(!CarPlaySettingsView.showsFlowsWithPlaylists(alone))
        #expect(try await homeFlows(alone).isEmpty)
        alone.noteFlowPlayed(playlistId: "pl-dw", at: t0)
        #expect(alone.flowPlays.isEmpty, "not a flow without Aurral")
        alone.signOut()
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(HomeAndLibraryView.showsFlowsSection(model) && CarPlaySettingsView.showsFlowsWithPlaylists(model))
        #expect(try await !homeFlows(model).isEmpty)
    }
}
