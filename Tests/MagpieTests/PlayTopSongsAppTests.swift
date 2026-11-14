import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Search
import Testing
@testable import Magpie

private let artistMBID = MBID("4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11")!

/// Round 27 A (owner item 1, 2026-11-14: "When you go into an artist, there should be an option to play the top songs. It
/// should start in sequence, but in the queue there should be maximum 15 of the top songs so you can then select to
/// shuffle them."; D303, D304, D308): Play top songs end to end against a mock Navidrome: the list known at the tap plays
/// at once, the rest is filled behind in order, and an artist Lidarr has plays their saved fifteen.
@MainActor @Suite(.serialized) final class PlayTopSongsAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "PlayTopSongsAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "PlayTopSongsAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = TopSongsRouting()
    let nav = DiscoverNavidrome()
    let library = AutomixLibrary()

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    init() {
        library.install(on: transport.mock)
    }

    func model(lidarr: Bool = false, aurral: Bool = false) async throws -> AppModel {
        transport.aurral.useAurral213()
        nav.install(on: transport.mock)
        transport.mock.stub(pathSuffix: "/api/v1/artist", body: Data("[]".utf8))
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: URL(string: "http://192.168.1.2:8686")!, apiKey: "test-key")) }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(nil),
                             aurralStore: MemoryAurralStore(), matchIndexDirectory: nil, dataDirectory: tmp,
                             transport: transport, probeTransport: transport, engine: FakeEngine(),
                             previewTransport: transport, defaults: defaults, systemNowPlaying: false,
                             notifications: false, network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        model.aurralFeeds.phoneRegion = { nil }
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "jordan", password: "pw")
        await model.refreshMusicFolders()
        if aurral {
            _ = try await model.connectAurral(base: transport.aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return model
    }

    private func songs(_ ids: [String]) throws -> [Song] { try ids.map { try #require(library.song($0)) } }
    private func mainIds(_ model: AppModel) -> [String] { model.player.queue.main.map(\.song.id) }
    private let allTop = ["own3", "own1", "own5", "own2", "own8", "own4", "own6", "own7"]

    private func request(_ known: [Song], complete: Bool = false) -> TopSongsPlayRequest {
        TopSongsPlayRequest(name: "Aurora Field", mbid: artistMBID, known: known, complete: complete, provider: nil)
    }

    /// Fifteen songs of a big library: Navidrome's top songs for the artist.
    private func bigLibrary() {
        library.update { s in
            s.own = (1...20).map {
                AutomixLibrary.Row(id: "own\($0)", title: "Own \($0)", artist: "Aurora Field", artistId: "ar1", albumId: "al-1")
            }
            s.topSongs = (1...20).map { "own\($0)" }
        }
    }

    // MARK: - Fifteen behind five (D303)

    @Test func cache_keepsFifteen() throws {
        let cache = LidarrTopSongsCache(root: tmp, scope: "abc")
        let rows = (1...20).map {
            LidarrTopSongs.Row(song: Song(id: "s\($0)", title: "Song \($0)", artist: "Aurora Field", album: "A", duration: 200),
                               source: .library)
        }
        cache.save(rows, key: "id:ar1")
        #expect(cache.load("id:ar1")?.map(\.id) == (1...15).map { "s\($0)" })
        #expect(LidarrTopSongsCache.maxRows == 15)
    }

    @Test func lidarrModel_showsFiveHoldsFifteen() async throws {
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        let scope = try #require(model.navidromeScope)
        let rows = try songs((1...8).map { "own\($0)" }).map { LidarrTopSongs.Row(song: $0, source: .library) }
        LidarrTopSongsCache(root: tmp, scope: scope).save(rows, key: "mbid:\(artistMBID.rawValue)")
        let page = try #require(await model.lidarrTopSongs(name: "Aurora Field", mbid: artistMBID, artistId: "ar1"))
        #expect(page.playable.map(\.id) == (1...8).map { "own\($0)" })
        #expect(page.songs.map(\.id) == (1...5).map { "own\($0)" }, "five shown")
        #expect(page.display(fallback: []) == .lidarr(Array(page.playable.prefix(5))))
    }

    // MARK: - Play top songs (D304)

    @Test func playTopSongs_lidarrArtistUsesSavedFifteen() async throws {
        bigLibrary()
        let model = try await model(lidarr: true)
        defer { model.signOut() }
        let scope = try #require(model.navidromeScope)
        let saved = try songs((1...15).reversed().map { "own\($0)" })
        LidarrTopSongsCache(root: tmp, scope: scope).save(saved.map { LidarrTopSongs.Row(song: $0, source: .aurral) },
                                                          key: "mbid:\(artistMBID.rawValue)")
        let page = try #require(await model.lidarrTopSongs(name: "Aurora Field", mbid: artistMBID, artistId: "ar1"))
        let before = transport.count("/rest/getTopSongs")
        await model.playTopSongs(request(page.playable, complete: true))
        await model.queueBuilder.task?.value
        #expect(mainIds(model) == saved.map(\.id), "their saved fifteen, in order")
        #expect(model.player.queue.currentIndex == 0 && !model.player.isShuffled)
        #expect(transport.count("/rest/getTopSongs") == before, "nothing to fill: no read")
    }

    @Test func playTopSongs_inOrderMaxFifteen() async throws {
        bigLibrary()
        let model = try await model()
        defer { model.signOut() }
        await model.playTopSongs(request(try songs(["own4", "own2"])))
        await model.queueBuilder.task?.value
        #expect(mainIds(model) == ["own4", "own2", "own1", "own3"] + (5...15).map { "own\($0)" })
        #expect(mainIds(model).count == 15)
    }

    @Test func playTopSongs_otherArtistLibraryRowsThenNavidrome() async throws {
        let model = try await model()
        defer { model.signOut() }
        await model.playTopSongs(request(try songs(["own5", "own2"])))
        await model.queueBuilder.task?.value
        #expect(mainIds(model) == ["own5", "own2", "own3", "own1", "own8", "own4", "own6", "own7"])
    }

    @Test func playTopSongs_neverDiscoverCopyOrFind() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.discover.flowSongIds = ["own3"]
        model.findsIdentity.markLanded("own1")
        await model.playTopSongs(request(try songs(["own1", "own5"])))
        await model.queueBuilder.task?.value
        #expect(mainIds(model) == ["own5", "own2", "own8", "own4", "own6", "own7"])
    }

    @Test func playTopSongs_hiddenWithNoLibrarySong() async throws {
        let model = try await model()
        defer { model.signOut() }
        #expect(model.topSongsPlayable([]).isEmpty)
        model.discover.flowSongIds = ["own3"]
        #expect(model.topSongsPlayable(try songs(["own3"])).isEmpty, "only a Discover copy: no button")
        #expect(model.topSongsPlayable(try songs(["own3", "own2"])).map(\.id) == ["own2"])
        await model.playTopSongs(request([]))
        #expect(model.player.queue.main.isEmpty)
    }

    /// Offline only songs on the phone play, and nothing is read to fill.
    @Test func playTopSongs_offlineOnlyOnThePhone() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let before = transport.count("/rest/getTopSongs")
        await model.playTopSongs(request(try songs(["own1", "own2"])))
        await model.queueBuilder.task?.value
        #expect(model.player.queue.main.isEmpty, "neither is on the phone")
        #expect(transport.count("/rest/getTopSongs") == before)
    }

    @Test func playTopSongs_startsBeforeFillCompletes() async throws {
        let model = try await model()
        defer { model.signOut() }
        transport.hold("/rest/getTopSongs")
        defer { transport.release("/rest/getTopSongs") }
        await model.playTopSongs(request(try songs(["own5", "own2"])))
        #expect(mainIds(model) == ["own5", "own2"] && model.player.queue.current?.song.id == "own5", "plays at once")
        transport.release("/rest/getTopSongs")
        await model.queueBuilder.task?.value
        #expect(mainIds(model).count == 8)
    }

    @Test func playTopSongs_fillStopsWhenAnotherPlayStarts() async throws {
        let model = try await model()
        defer { model.signOut() }
        transport.hold("/rest/getTopSongs")
        defer { transport.release("/rest/getTopSongs") }
        await model.playTopSongs(request(try songs(["own5", "own2"])))
        #expect(await eventually { self.transport.count("/rest/getTopSongs") == 1 })
        model.play(try songs(["gen1", "gen2"]), startAt: 0)
        transport.release("/rest/getTopSongs")
        await model.queueBuilder.task?.value
        #expect(mainIds(model) == ["gen1", "gen2"])
    }

    /// "so you can then select to shuffle them": shuffle works on the queue, which holds only the top songs.
    @Test func playTopSongs_shuffleShufflesOnlyThose() async throws {
        let model = try await model()
        defer { model.signOut() }
        await model.playTopSongs(request(try songs(["own3"])))
        await model.queueBuilder.task?.value
        model.player.setShuffled(true, seed: 5)
        #expect(Set(mainIds(model)) == Set(allTop) && mainIds(model).count == allTop.count)
    }

    /// "Ask before replacing the queue": the fill waits for the answer and lands only on Replace.
    @Test func playTopSongs_asksFirstThenFills() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.updatePreferences { $0.playback.askBeforeReplacingQueue = true }
        model.player.play(try songs(["gen1", "gen2"]), startAt: 0)
        await model.playTopSongs(request(try songs(["own5"])))
        let pending = try #require(model.queueActions.pendingReplace)
        #expect(mainIds(model) == ["gen1", "gen2"])
        model.answer(pending, .replace)
        await model.queueBuilder.task?.value
        #expect(mainIds(model) == ["own5", "own3", "own1", "own2", "own8", "own4", "own6", "own7"])
    }

    @Test func fourSetups() async throws {
        var queues: [[String]] = []
        for (lidarr, aurral) in [(false, false), (true, false), (false, true), (true, true)] {
            let model = try await model(lidarr: lidarr, aurral: aurral)
            await model.playTopSongs(TopSongsPlayRequest(name: "Aurora Field", mbid: nil, known: try songs(["own5"]),
                                                         complete: false, provider: nil))
            await model.queueBuilder.task?.value
            queues.append(mainIds(model))
            model.signOut()
        }
        #expect(queues.allSatisfy { $0 == ["own5", "own3", "own1", "own2", "own8", "own4", "own6", "own7"] })
    }
}
