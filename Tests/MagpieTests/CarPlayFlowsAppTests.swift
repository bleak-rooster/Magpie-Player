import AurralKit
import CarPlay
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import CarPlayUI
@testable import Magpie

/// The stub Aurral and the mock Navidrome (`AurralRouting`), with Aurral's answers held back while `hold()` is on, and
/// each path's requests counted. Never the owner's.
final class HeldAurral: HTTPTransport, @unchecked Sendable {
    let inner = AurralRouting()
    private let lock = NSLock()
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var counts: [String: Int] = [:]

    func hold() { lock.withLock { held = true } }

    func release() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held = false
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    /// Requests whose path contains `path` so far.
    func hits(_ path: String) -> Int { lock.withLock { counts.filter { $0.key.contains(path) }.values.reduce(0, +) } }
    /// Aurral requests waiting now.
    var heldCount: Int { lock.withLock { waiting.count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { counts[request.url?.path ?? "", default: 0] += 1 }
        if request.url?.host == inner.aurral.host {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let goes = lock.withLock { () -> Bool in
                    guard held else { return true }
                    waiting.append(continuation)
                    return false
                }
                if goes { continuation.resume() }
            }
        }
        return try await inner.send(request)
    }
}

/// Round 27 H (owner, 2026-11-14): "In carplay, in the home screen, it should present the flows as the latest one that
/// was played, not in alphabetical order" (D297) and "there should be a switch in the settings to show aurral
/// playlists/flows and playlists combined" (D300); another user's flow says whose in the car (D299). The app's adapter
/// and the controller, against the stub Aurral and a mock Navidrome.
@MainActor @Suite(.serialized) final class CarPlayFlowsAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "CarPlayFlowsAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "CarPlayFlowsAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    /// Fix round 1 (I1): Aurral's answers can be held back, to show a slow Aurral holds nothing else up.
    let gate = HeldAurral()
    var transport: AurralRouting { gate.inner }
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()
    var aurral: StubAurral { transport.aurral }

    deinit {
        gate.release()
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), aurralStore: aurralStore,
                 matchIndexDirectory: nil, dataDirectory: tmp, transport: gate, probeTransport: gate,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                 network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
    }

    /// As HomeFlowsOrderAppTests: the user's "Discover Weekly" (pl-dw) and "Trending Mix" (pl-empty), Sam's "Late
    /// Night" (pl-sam), and the owner's own "Road trip" (pl-road).
    private func signedIn() async throws -> AppModel {
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
        _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                          password: StubAurral.defaultPassword)
        await model.refreshDiscover(force: true)
        return model
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// The car's Discover home shelf: its playlist ids and their rows' details.
    private func carHome(_ adapter: CarPlayLibraryAdapter) async throws -> (ids: [String], details: [String?]) {
        let shelves = try await adapter.homeShelves([.discover], size: CarPlayRows.homeShelfMaxSize)
        let ids = (shelves.first?.items ?? []).compactMap { item in if case .playlist(let p) = item { p.id } else { nil } }
        return (ids, CarPlayRows.home(shelves).flatMap(\.rows).map(\.detail))
    }

    private func setCombined(_ model: AppModel, _ on: Bool) { model.updatePreferences { $0.carPlay.flowsWithPlaylists = on } }

    // MARK: - D297: the car's Home, by last played

    /// Fix round 1 (I1): the car's Discover shelf is read alongside the others. With Aurral holding its answer, the
    /// Playlists shelf is already being read from the library well inside Discover's 3 s wait; both shelves come.
    @Test func carHome_slowAurralHoldsNothingElseUp() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let adapter = CarPlayLibraryAdapter(model: model)
        model.discover.now = { Date().addingTimeInterval(120) }   // Discover is due a fresh read of Aurral
        let before = gate.hits("getPlaylists")
        gate.hold()
        let read = Task { try await adapter.homeShelves([.discover, .playlists], size: 4) }
        #expect(await eventually(2) { self.gate.hits("getPlaylists") > before && self.gate.heldCount > 0 },
                "the library's Playlists shelf waited for Aurral")
        gate.release()
        let shelves = try await read.value
        #expect(shelves.map(\.section) == [.discover, .playlists])
    }

    @Test func carHome_lastPlayedThenAtoZ() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.showEveryonesFlows = true
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(try await carHome(adapter).ids == ["pl-dw", "pl-sam", "pl-empty"], "none played: A to Z")
        model.noteFlowPlayed(playlistId: "pl-empty", at: t0)
        model.noteFlowPlayed(playlistId: "pl-sam", at: t0.addingTimeInterval(9))
        #expect(try await carHome(adapter).ids == ["pl-sam", "pl-empty", "pl-dw"], "played newest first, then A to Z")
        // Always, whatever Home's own order on the phone.
        model.setHomeFlowsOrder(.alphabetical)
        #expect(try await carHome(adapter).ids == ["pl-sam", "pl-empty", "pl-dw"])
    }

    /// The controller notes a play when a playlist's page starts one (its Play row here); the adapter records it only
    /// for a flow.
    @Test func flowPlays_recordedFromCar() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let car = FakeCarInterface()
        let adapter = CarPlayLibraryAdapter(model: model)
        let controller = CarPlayController(interfaceController: car, library: adapter, player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "a"))
        controller.open(.playlist(id: "pl-dw", title: "Discover Weekly"))
        #expect(await eventually { FakeCarInterface.texts(car.topList).contains("Play") }, "\(FakeCarInterface.texts(car.topList))")
        #expect(model.flowPlays.isEmpty)
        car.tap("Play", in: car.topList)
        #expect(model.flowPlays["pl-dw"] != nil)

        controller.open(.playlist(id: "pl-road", title: "Road trip"))
        #expect(await eventually { FakeCarInterface.texts(car.topList).contains("Shuffle") && car.topList?.title == "Road trip" })
        car.tap("Shuffle", in: car.topList)
        #expect(model.flowPlays["pl-road"] == nil, "not a flow")
        adapter.notePlaylistPlayed(id: "pl-empty")
        #expect(model.flowPlays["pl-empty"] != nil)
    }

    // MARK: - D299: whose flow, in the car

    @Test func carRow_captionOnlyForOthers() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let adapter = CarPlayLibraryAdapter(model: model)
        model.showEveryonesFlows = true
        let home = try await carHome(adapter)
        let samIndex = try #require(home.ids.firstIndex(of: "pl-sam"))
        #expect(home.details[samIndex]?.hasSuffix(" \u{00B7} sam") == true, "\(home.details)")
        #expect(home.details.enumerated().filter { $0.offset != samIndex }.allSatisfy { $0.element?.contains("\u{00B7}") == false })
        #expect(adapter.discoverOwnerCaption(playlistId: "pl-sam") == "sam")
        #expect(adapter.discoverOwnerCaption(playlistId: "pl-dw") == nil)
        model.showEveryonesFlows = false
        #expect(adapter.discoverOwnerCaption(playlistId: "pl-sam") == nil)
    }

    // MARK: - D300: flows with your playlists

    @Test func car_offIsToday() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(!model.preferences.carPlay.flowsWithPlaylists)
        let ids = Set(try await adapter.playlists().map(\.id))
        #expect(ids.isDisjoint(with: ["pl-dw", "pl-empty", "pl-sam"]), "Discover's stay out (D185): \(ids)")
        #expect(adapter.libraryRows.contains(.discover))
    }

    @Test func car_combinedMixesAtoZ() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let adapter = CarPlayLibraryAdapter(model: model)
        setCombined(model, true)
        let list = try await adapter.playlists()
        #expect(Set(list.map(\.id)).isSuperset(of: ["pl-dw", "pl-empty", "pl-road"]), "\(list.map(\.id))")
        #expect(!list.contains { $0.id == "pl-sam" }, "another user's only with everyone's on")
        let names = list.map(\.name)
        #expect(names == names.sorted { $0.compare($1, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedDescending })
        let rows = CarPlayRows.playlistBands(list, signedInUser: adapter.playlistCaptionUser).flatMap(\.rows)
        #expect(rows.allSatisfy { $0.detail?.contains("\u{00B7}") == false }, "every one is yours: \(rows.map(\.detail))")
        // A flow opens with the library's copies in place, as from Discover.
        let page = try await adapter.playlist(id: "pl-dw")
        #expect(page.0.id == "pl-dw")
    }

    @Test func car_combinedHidesDiscoverRow() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(adapter.libraryRows.contains(.discover))
        #expect(!adapter.flowsWithPlaylists)
        setCombined(model, true)
        #expect(adapter.flowsWithPlaylists, "the layout watch sees the switch and builds the tabs again")
        #expect(!adapter.libraryRows.contains(.discover))
        #expect(model.libraryRows.contains(.discover), "the phone's Library is unchanged")
        #expect(CarPlayRows.libraryRoot(adapter.libraryRows).flatMap(\.rows).allSatisfy { $0.title != "Discover" })
    }

    @Test func car_combinedRespectsYoursAndEveryone() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let adapter = CarPlayLibraryAdapter(model: model)
        setCombined(model, true)
        model.showEveryonesFlows = true
        model.playlistShow = .yours
        let list = try await adapter.playlists()
        #expect(list.contains { $0.id == "pl-sam" } && list.contains { $0.id == "pl-dw" })
        let user = try #require(adapter.playlistCaptionUser, "names others' flows in Yours too")
        let rows = CarPlayRows.playlistBands(list, signedInUser: user).flatMap(\.rows)
        let sam = try #require(rows.first { $0.id == "playlist.pl-sam" })
        #expect(sam.detail?.hasSuffix(" \u{00B7} sam") == true, "\(String(describing: sam.detail))")
        #expect(rows.first { $0.id == "playlist.pl-dw" }?.detail?.contains("\u{00B7}") == false)
        model.showEveryonesFlows = false
        #expect(try await !adapter.playlists().contains { $0.id == "pl-sam" })
        setCombined(model, false)
        #expect(adapter.playlistCaptionUser == nil, "Yours without the switch: as before")
    }

    /// Offline, the downloaded flows Discover shows join the downloaded playlists (`offlinePlaylists`' rule).
    @Test func car_combinedOfflineIncludesDownloadedDiscover() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.showEveryonesFlows = false
        let downloaded = ["pl-dw", "pl-sam", "pl-road"].map { Playlist(id: $0, name: $0, songCount: 1, duration: 1) }
        #expect(model.carOfflinePlaylists(downloaded, combined: false).map(\.id) == ["pl-road"])
        #expect(model.carOfflinePlaylists(downloaded, combined: true).map(\.id).sorted() == ["pl-dw", "pl-road"])
        model.showEveryonesFlows = true
        #expect(model.carOfflinePlaylists(downloaded, combined: true).map(\.id).sorted() == ["pl-dw", "pl-road", "pl-sam"])
    }

    /// The car's Home doesn't change with the switch (D300).
    @Test func carHomeUnchangedByCombined() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        let adapter = CarPlayLibraryAdapter(model: model)
        let sections = adapter.homeSections
        let before = try await carHome(adapter)
        setCombined(model, true)
        #expect(adapter.homeSections == sections)
        #expect(try await carHome(adapter).ids == before.ids)
    }

    // MARK: - Settings › CarPlay (D300)

    @Test func carSettingsCopy() async throws {
        #expect(CarPlayFlowsCopy.toggle == "Flows with your playlists")
        #expect(CarPlayFlowsCopy.footer == "Your flows and Aurral playlists also appear in the car\u{2019}s Playlists list, A to Z.")
    }
}
