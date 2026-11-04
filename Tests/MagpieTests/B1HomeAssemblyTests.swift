import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Testing
import UIKit
@testable import Magpie

private func ok(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

/// A provider whose Recommended never answers (B1): Home must not wait for it.
@MainActor @Observable final class SilentHomeShelves: HomeAurralShelves {
    var availableSections: Set<HomeSection> = [.recommended, .newThisWeek]
    private(set) var asked: [HomeSection] = []
    func items(for section: HomeSection, limit: Int) async throws -> [HomeOutsideItem] {
        asked.append(section)
        if section == .newThisWeek { return [HomeOutsideItem(kind: .artist, key: "new-1", title: "New One")] }
        try await Task.sleep(for: .seconds(600))   // a stuck connection
        return []
    }
    func route(for item: HomeOutsideItem, in section: HomeSection) -> Route? { nil }
    func artwork(for item: HomeOutsideItem, side: CGFloat) async -> UIImage? { nil }
}

/// B1 (owner's build-14 screenshots): Home showed random library albums under Your flows, Recommended for you, New
/// this week, the quick grid, Jump back in and Recently added, and never showed More playlists for you.
///
/// Root cause: `homeRead` paired each section's answer with its position as
/// `do { return (index, .success(try await homeItems(section))) } catch { … }`. The optimised (Release) build loses
/// `index` across that await, so every answer was written to position 0: the first section asked showed whichever
/// section finished last (often Random albums, the slowest list), and the others counted as "not read" and were asked
/// again, one by one, each time getting another section's tiles. Debug builds were right, so every test passed.
///
/// These tests catch it when run in the Release configuration (`-configuration Release ENABLE_TESTABILITY=YES
/// SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`); in Debug they guard the same behaviour.
@MainActor @Suite(.serialized) final class B1HomeAssemblyTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "B1HomeAssemblyTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "B1HomeAssemblyTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = SlowAurralRouting()
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()
    var aurral: StubAurral { transport.aurral }

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    nonisolated static func album(_ id: String) -> HomeShelf.Item {
        .album(Album(id: id, name: id, artist: "A", songCount: 1, duration: 60))
    }

    /// Each list type answers its own albums: `<type>-1`, `<type>-2`.
    func signedIn(aurral withAurral: Bool) async throws -> AppModel {
        transport.navidrome.stub(pathSuffix: "/rest/getAlbumList2") { request in
            let type = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "type" }?.value ?? "?"
            let albums = (1...2).map { #"{"id":"\#(type)-\#($0)","name":"\#(type) \#($0)","artist":"R","songCount":1,"duration":60}"# }
            return .init(status: 200, body: ok(#""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#))
        }
        nav.install(on: transport.navidrome)
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly")])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        if withAurral {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return model
    }

    private func ids(_ shelves: [HomeShelf], _ section: HomeSection) -> [String]? {
        shelves.first { $0.section == section }?.items.map(\.id)
    }

    static let artist = HomeOutsideItem(kind: .artist, key: "mbid-1", title: "Ada Okafor")

    /// Every section read together gets its own tiles, whichever finishes first.
    @Test func everySectionKeepsItsOwnTiles() async throws {
        let model = try await signedIn(aurral: true)
        defer { model.signOut() }
        let fake = FakeHomeShelves([.recommended, .newThisWeek, .trending])
        fake.items[.recommended] = [Self.artist]
        fake.items[.newThisWeek] = [HomeOutsideItem(kind: .artist, key: "mbid-2", title: "Lior Ben")]
        model.homeAurralShelves = fake
        let wanted: [HomeSection] = [.greeting, .filterChips, .quickAccess, .discover, .recommended, .newThisWeek,
                                     .jumpBackIn, .recentlyAdded, .mostPlayed, .randomAlbums, .trending]
        let read = try await model.homeRead(for: wanted)
        #expect(ids(read.shelves, .quickAccess) == ["album-recent-1", "album-recent-2"])
        #expect(ids(read.shelves, .jumpBackIn) == ["album-recent-1", "album-recent-2"])
        #expect(ids(read.shelves, .recentlyAdded) == ["album-newest-1", "album-newest-2"])
        #expect(ids(read.shelves, .mostPlayed) == ["album-frequent-1", "album-frequent-2"])
        #expect(ids(read.shelves, .randomAlbums) == ["album-random-1", "album-random-2"])
        #expect(ids(read.shelves, .recommended) == ["outside-artist-mbid-1"])
        #expect(ids(read.shelves, .newThisWeek) == ["outside-artist-mbid-2"])
        #expect(read.failed.isEmpty && read.cancelled.isEmpty, "every section answered")
        for shelf in read.shelves {
            #expect(shelf.items.allSatisfy { HomeShelf.fits($0, in: shelf.section) }, "\(shelf.section)")
        }
    }

    /// Home's feed on a build-13 phone: the saved shelves (build 13's sections, incl. Discover's playlist and Random
    /// albums) show at once, and the first read replaces each with its own section's tiles; nothing lands under another
    /// section, and the provided sections fill in.
    @Test func aBuild13SavedHomeReadsEachSectionRight() async throws {
        let model = try await signedIn(aurral: true)
        defer { model.signOut() }
        let fake = FakeHomeShelves([.recommended, .newThisWeek])
        fake.items[.recommended] = [Self.artist]
        model.homeAurralShelves = fake
        let scope = try #require(model.navidromeScope)
        let cache = HomeShelfCache(root: tmp, scope: scope)
        cache.save([HomeShelf(section: .jumpBackIn, items: [Self.album("old-jb")]),
                    HomeShelf(section: .recentlyAdded, items: [Self.album("old-ra")]),
                    HomeShelf(section: .randomAlbums, items: [Self.album("old-rnd")]),
                    HomeShelf(section: .discover, items: [.playlist(Playlist(id: "pl-dw", name: "Discover Weekly",
                                                                             songCount: 4, duration: 0))])])
        model.homeFeedSlot?.stop()
        model.homeFeedSlot = nil
        let feed = model.homeFeed
        #expect(feed.load?.found[.jumpBackIn]?.items.map(\.id) == ["album-old-jb"], "the saved shelf shows at once")
        let sections: [HomeSection] = [.greeting, .filterChips, .quickAccess, .discover, .recommended, .newThisWeek,
                                       .jumpBackIn, .recentlyAdded, .randomAlbums]
        await feed.show(.make(sections: sections, offline: false, onPhone: nil, genres: .defaultValue))
        let found = try #require(feed.load?.found)
        #expect(found[.jumpBackIn]?.items.map(\.id) == ["album-recent-1", "album-recent-2"])
        #expect(found[.recentlyAdded]?.items.map(\.id) == ["album-newest-1", "album-newest-2"])
        #expect(found[.randomAlbums]?.items.map(\.id) == ["album-random-1", "album-random-2"])
        #expect(found[.recommended]?.items.map(\.id) == ["outside-artist-mbid-1"])
        for (section, shelf) in found {
            #expect(shelf.items.allSatisfy { HomeShelf.fits($0, in: section) }, "\(section)")
        }
        let saved = Dictionary(uniqueKeysWithValues: cache.load().map { ($0.section, $0.items.map(\.id)) })
        #expect(saved[.recentlyAdded] == ["album-newest-1", "album-newest-2"], "what is saved reads back the same")
        #expect(saved[.recommended] == ["outside-artist-mbid-1"])
    }

    /// D121: shelves saved by builds 13 and 14 (file version 1) are not shown: build 14 saved other sections' tiles
    /// under Jump back in, Recently added and the quick grid. Home reads them fresh once instead.
    @Test func savedShelvesFromBuild14AreNotShown() throws {
        let root = tmp.appending(path: "v1")
        let cache = HomeShelfCache(root: root, scope: "abc")
        try FileManager.default.createDirectory(at: cache.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let v1 = #"{"version":1,"shelves":[{"section":"jumpBackIn","items":[{"kind":"album","id":"rnd-1","title":"Volo","subtitle":"Goblin"}]}]}"#
        try Data(v1.utf8).write(to: cache.url)
        #expect(cache.load().isEmpty, "a build-14 file is dropped")
        cache.save([HomeShelf(section: .jumpBackIn, items: [Self.album("recent-1")])])
        #expect(cache.load().map(\.section) == [.jumpBackIn], "this build's own file reads back")
    }

    /// A provider that never answers Recommended holds nothing up: the library's shelves and New this week arrive,
    /// Recommended counts as not read (retried later, never "Couldn't load").
    @Test func aSilentProviderNeverHoldsHomeUp() async throws {
        let model = try await signedIn(aurral: true)
        defer { model.signOut() }
        model.homeAurralShelves = SilentHomeShelves()
        let start = ContinuousClock.now
        let read = try await model.homeRead(for: [.recommended, .newThisWeek, .jumpBackIn, .recentlyAdded])
        #expect(ContinuousClock.now - start < AppModel.providedWait + .seconds(3), "bounded by the provided wait")
        #expect(ids(read.shelves, .jumpBackIn) == ["album-recent-1", "album-recent-2"])
        #expect(ids(read.shelves, .recentlyAdded) == ["album-newest-1", "album-newest-2"])
        #expect(ids(read.shelves, .newThisWeek) == ["outside-artist-new-1"])
        #expect(read.cancelled == [.recommended] && read.failed.isEmpty, "not read yet, not a failure")
    }

    /// The deadline itself: an answer in time is returned; a silent one is cut off as "not read".
    @Test func homeDeadline() async {
        let quick = await Deadline.run(.seconds(5)) { 7 }
        #expect((try? quick.get()) == 7)
        let silent = await Deadline.run(.milliseconds(50)) { () async throws -> Int in
            try await Task.sleep(for: .seconds(600))
            return 1
        }
        if case .failure(let error) = silent { #expect(error is Deadline.Exceeded) } else { Issue.record("no deadline") }
    }
}
